module Main where

import Control.Monad
import Control.Monad.IO.Class
import Data.Map.Strict qualified as M
import Data.Maybe
import Data.Text qualified as T
import Defines
import GI.Gtk.Objects.CssProvider qualified as Gtk
import System.Environment
import System.Exit
import System.IO
import System.Log.Handler.Simple
import System.Log.Logger
import UI.Application qualified as UI
import UI.Commons qualified as UI
import UI.Containers qualified as UI
import UI.Window qualified as UI
import UI.X11.Desktops qualified as UI

workspaceMaps :: M.Map String String
workspaceMaps =
  M.fromList
    [ (wmain, "\xe3af")
    , (docs, "\xf0c7")
    , (code, "\xf121")
    , (term, "\xf120")
    , (chat, "\xf4ad")
    , (pics, "\xf03e")
    , (game, "\xf43c")
    ]

main :: IO ()
main = do
  Just app <- UI.applicationNew (Just $ T.pack "pulp.ui.taskbar") []
  UI.onApplicationActivate app (activating app)
  status <- UI.applicationRun app Nothing
  when (status /= 0) $ exitWith (ExitFailure $ fromIntegral status)
  where
    mayLabel n = fromMaybe n $ T.pack <$> workspaceMaps M.!? T.unpack n
    desktopVis :: IO UI.Widget
    desktopVis = do
      liftIO $ do
        -- Wat in tarnation, having to do just for logging?
        logger <- getLogger "DeskVis"
        handler <- streamHandler stderr INFO
        saveGlobalLogger $ setLevel INFO . setHandlers [handler] $ logger
      liftIO $ infoM "DeskVis" "Starting desktop visualizer..."
      hPutStrLn stderr "Hmmm"
      UI.deskVisNew (maybe (T.pack "NONE") mayLabel) UI.defImageSetter

    cssProv :: IO Gtk.CssProvider
    cssProv = do
      css <- Gtk.cssProviderNew
      cfgDir <- getEnv "XMONAD_CONFIG_DIR"
      Gtk.cssProviderLoadFromPath css $ T.pack (cfgDir </> "styles" </> "taffybar.css")
      pure css

    activating :: UI.Application -> IO ()
    activating app = do
      cssProv >>= flip UI.defscreenAddStyleContext UI.STYLE_PROVIDER_PRIORITY_USER

      window <- UI.appWindowNew app
      UI.windowSetTitle window (T.pack "Pulp Taskbar")
      UI.windowSetDock window UI.DockBottom (UI.AbsoluteSize 40) (UI.DockSpan (1 / 6) (5 / 6))
      UI.windowSetKeepAbove window True
      UI.windowSetSkipPagerHint window True
      UI.windowSetSkipTaskbarHint window True

      UI.windowSetTransparent window

      UI.containerAdd window =<< desktopVis

      UI.widgetShowAll window
