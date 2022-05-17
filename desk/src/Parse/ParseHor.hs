module Parse.ParseHor (
  P.label,
  parseFile,
  skipH,
  remainH,
  identH,
  symbolH,
  decimalH,
  eoH,
  fields,
  fieldsWithHead,
  exQueryMap,
  queryOpt,
  queryOptAs,
  queryField,
  queryFieldAs,
  queryAll,
  queryAllAs,
) where

import Control.Applicative
import Control.Applicative.Combinators
import Control.Monad.Except
import Control.Monad.State
import Data.Char
import Data.Map.Strict qualified as M
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Void
import Text.Megaparsec qualified as P
import Text.Megaparsec.Char qualified as P
import Text.Megaparsec.Char.Lexer qualified as Lex
import Text.Printf

-- | Parses a file using a parser.
parseFile :: P.Parsec Void T.Text a -> FilePath -> IO a
parseFile parser path =
  P.parse parser path <$> T.readFile path >>= \case
    Left err -> fail $ P.errorBundlePretty err
    Right result -> pure result

-- | Skips horizontal spaces.
skipH :: P.MonadParsec e T.Text m => m ()
skipH = Lex.space P.hspace1 empty empty

-- | Parses remaining characters until a line break.
remainH :: P.MonadParsec e T.Text m => m T.Text
remainH = P.takeWhileP (Just "remaining") $ (/= '\n')

-- | Space-separated identifier, which could include numbers, '_', '(' and ')'.
identH :: P.MonadParsec e T.Text m => m T.Text
identH = Lex.lexeme skipH (P.takeWhile1P (Just "identifier") isID)
  where
    isID c = isAlphaNum c || c == '(' || c == ')' || c == '_'

-- | Horizontal symbols.
symbolH :: P.MonadParsec e T.Text m => T.Text -> m T.Text
symbolH = Lex.symbol skipH

-- | Horizontal decimals.
decimalH :: (P.MonadParsec e T.Text m, Num a) => m a
decimalH = Lex.lexeme skipH Lex.decimal

-- | Parse an end of line, or eof.
eoH :: P.MonadParsec e T.Text m => m ()
eoH = () <$ P.eol <|> P.eof

-- | Parse fields as a map.
fields :: P.MonadParsec e T.Text m => m a -> m (M.Map T.Text a)
fields pval = M.fromList <$> field `sepEndBy` eoH
  where
    field = P.label "field" $ (,) <$> identH <*> pval

-- | Parse fields as a map, with heading ignored for each line.
fieldsWithHead :: P.MonadParsec e T.Text m => m hd -> m a -> m (M.Map T.Text a)
fieldsWithHead hd pval = M.fromList <$> field `sepEndBy` eoH
  where
    field = P.label "field" $ (,) <$> (hd *> identH) <*> pval

-- | Map query monad.
newtype QueryMap b a = QueryMap (ExceptT String (State (M.Map T.Text b)) a)
  deriving (Functor, Applicative, Monad)

-- MAYBE Log all the failures?

instance MonadFail (QueryMap b) where
  fail = QueryMap . throwError

-- | Execute QueryMap.
exQueryMap :: (MonadFail m, Show b) => QueryMap b a -> M.Map T.Text b -> m a
exQueryMap (QueryMap query) st = either (fail . errMsg) pure $ evalState (runExceptT query) st
  where
    errMsg msg = printf "Error: %s\nIll-formed map: %s\n" msg (show st)

-- | Query an optional field.
queryOpt :: T.Text -> QueryMap b (Maybe b)
queryOpt name = QueryMap . state $ M.updateLookupWithKey (\_ _ -> Nothing) name

-- | Query an optional field with a mapping function.
queryOptAs :: T.Text -> (b -> Maybe r) -> QueryMap b (Maybe r)
queryOptAs name f = (>>= f) <$> queryOpt name

-- | Query a field.
queryField :: T.Text -> QueryMap b b
queryField name = queryOpt name >>= maybe (fail notFoundErr) pure
  where
    notFoundErr = printf "Field %s not found" name

-- | Query a field with a mapping function.
queryFieldAs :: T.Text -> (b -> Maybe r) -> QueryMap b r
queryFieldAs name f = (f <$> queryField name) >>= maybe (fail illFormedErr) pure
  where
    illFormedErr = printf "Field %s ill-formed" name

-- | Query all fields satisfying predicate.
queryAll :: (T.Text -> Bool) -> QueryMap b (M.Map T.Text b)
queryAll pred = QueryMap . state $ M.partitionWithKey (\k _ -> pred k)

-- | Query all fields with predicate with a mapping function.
queryAllAs :: (T.Text -> Bool) -> (M.Map T.Text b -> Maybe r) -> QueryMap b r
queryAllAs pred f = do
  fs <- queryAll pred
  maybe (fail . illFormed $ M.keys fs) pure (f fs)
  where
    illFormed names = printf "Fields %s ill-formed" (show names)
