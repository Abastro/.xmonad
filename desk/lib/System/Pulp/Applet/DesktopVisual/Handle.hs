module System.Pulp.Applet.DesktopVisual.Handle (
  NumWindows,
  GetXIcon,
  DesktopSetup (..),
  WindowSetup (..),
  deskVisualizer,
) where

import Control.Concurrent.Task
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.Bifunctor (first)
import Data.Foldable
import Data.IORef
import Data.List
import Data.Map.Merge.Strict qualified as M
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Traversable
import Data.Vector qualified as V
import Graphics.X11.Types
import Status.X11.WMStatus
import Status.X11.XHandle
import System.Log.LogPrint
import System.Pulp.Applet.DesktopVisual.View qualified as View
import System.Pulp.PulpEnv
import UI.Commons qualified as UI
import UI.Pixbufs qualified as UI
import UI.Task qualified as UI
import View.Imagery qualified as View

deskCssClass :: DesktopState -> T.Text
deskCssClass = \case
  DeskActive -> T.pack "active"
  DeskVisible -> T.pack "visible"
  DeskHidden -> T.pack "hidden"

-- Okay, I know, but I cannot resist
winActiveCssClass :: () -> T.Text
winActiveCssClass = \case
  () -> T.pack "active"

windowCssClass :: WMStateEx -> T.Text
windowCssClass = \case
  WinHidden -> T.pack "hidden"
  WinDemandAttention -> T.pack "demanding"

type NumWindows = Word

-- | Desktop part of the setup.
data DesktopSetup = DesktopSetup
  { -- | Labeling rule for the desktop.
    desktopLabeling :: Maybe T.Text -> T.Text
  , -- | Whether to show certain desktop or not.
    showDesktop :: DesktopStat -> NumWindows -> Bool
  }

-- | Window part of the setup.
newtype WindowSetup = WindowSetup
  { -- | With which iamge the window is going to set to.
    windowImgSetter :: WindowInfo -> GetXIcon -> IO View.ImageSet
  }

-- TODO Configuration adjusting the icon size

-- | Desktops visualizer widget. Forks its own X11 event handler.
deskVisualizer :: DesktopSetup -> WindowSetup -> PulpIO UI.Widget
deskVisualizer deskSetup winSetup = do
  rcvs <- pulpXHandle deskVisInitiate
  deskVisualView <- View.deskVisualNew
  DeskVisHandle <- deskVisMake rcvs (deskSetup, winSetup) deskVisualView

  pure $ View.deskVisualWidget deskVisualView

-- Currently handle is empty, because no external handling is permitted.
data DeskVisHandle = DeskVisHandle

-- TODO Model scheme is not working, need to make it work with pure states. Later.
deskVisMake ::
  DeskVisRcvs ->
  (DesktopSetup, WindowSetup) ->
  View.DeskVisual ->
  PulpIO DeskVisHandle
deskVisMake DeskVisRcvs{..} (deskSetup, winSetup) view = withRunInIO $ \unlift -> do
  act <- registers <$> newIORef V.empty <*> newIORef M.empty <*> newIORef M.empty <*> newIORef Nothing
  unlift act
  where
    registers desksRef winsRef ordersRef activeRef = withRunInIO $ \unlift -> do
      killStat <- UI.uiTask desktopStats (unlift . updateDeskStats)
      killWinCh <- UI.uiTask windowsList (unlift . updateWinList)
      killActiv <- UI.uiTask windowActive (unlift . changeActivate)
      _ <- UI.onWidgetDestroy (View.deskVisualWidget view) (killStat >> killWinCh >> killActiv)
      pure DeskVisHandle
      where
        updateDeskStats :: V.Vector DesktopStat -> PulpIO ()
        updateDeskStats newStats = withRunInIO $ \unlift -> do
          -- Cut down to available desktops
          let numDesk = V.length newStats
          modifyIORef' desksRef (V.take numDesk)
          View.deskVisualCtrl view (View.CutDeskItemsTo numDesk)

          -- Add additional available desktops
          oldNum <- V.length <$> readIORef desksRef
          addeds <- for (V.drop oldNum $ V.indexed newStats) $ \(idx, stat) -> do
            deskItemView <- View.deskItemNew $ reqToDesktop idx
            (deskItemView,) <$> unlift (deskItemMake deskSetup stat deskItemView)
          modifyIORef' desksRef (<> fmap snd addeds)
          View.deskVisualCtrl view (View.AddDeskItems $ fmap fst addeds)

          -- Update all desktops
          deskItems <- readIORef desksRef
          V.zipWithM_ (\DeskItemHandle{updateDeskItem} -> updateDeskItem) deskItems newStats

        removeOldWin _window WinItemHandle{itemWindowView} = do
          UI.widgetDestroy (View.winItemWidget itemWindowView)
          pure False

        addNewWin window () = withRunInIO $ \unlift -> do
          winRcvs <- trackWinInfo window
          winItemView <- View.winItemNew $ reqActivate window
          let getIcon = winGetIcon window
          let switcher item x y = unlift (winSwitch window item x y)
          unlift $ winItemMake winSetup getIcon switcher winRcvs winItemView

        updateWinList :: V.Vector Window -> PulpIO ()
        updateWinList windows = withRunInIO $ \unlift -> do
          -- Update window maps
          oldWinMap <- readIORef winsRef
          let newWinMap = M.fromSet (const ()) . S.fromList . V.toList $ windows
          updWinMap <-
            unlift $
              M.mergeA
                (M.filterAMissing removeOldWin)
                (M.traverseMissing addNewWin)
                (M.zipWithMatched $ \_ handle _ -> handle)
                oldWinMap
                newWinMap
          writeIORef winsRef updWinMap

          -- Reorder windows appropriately
          let newOrder = M.fromList (V.toList windows `zip` [0 ..])
          writeIORef ordersRef newOrder
          curWins <- readIORef winsRef
          desktops <- readIORef desksRef
          for_ desktops $ \DeskItemHandle{reorderWinItems} -> reorderWinItems (newOrder M.!?) (curWins M.!?)

        changeActivate :: Maybe Window -> PulpIO ()
        changeActivate nextActive = withRunInIO $ \_unlift -> do
          windows <- readIORef winsRef
          prevActive <- atomicModifyIORef' activeRef (nextActive,)
          -- Little hack
          for_ (prevActive >>= (windows M.!?)) $ \WinItemHandle{itemWindowView} -> do
            View.widgetUpdateClass (View.winItemWidget itemWindowView) winActiveCssClass []
          for_ (nextActive >>= (windows M.!?)) $ \WinItemHandle{itemWindowView} -> do
            View.widgetUpdateClass (View.winItemWidget itemWindowView) winActiveCssClass [()]

        winSwitch :: Window -> View.WinItem -> Int -> Int -> PulpIO ()
        winSwitch windowId winView deskOld deskNew = withRunInIO $ \unlift -> do
          unlift $ logPrintf (T.pack "DeskVis") LevelInfo "[$1] desktop $2 -> $3" windowId deskOld deskNew
          desktops <- readIORef desksRef
          curOrders <- readIORef ordersRef
          -- Out of bounds: was already removed, no need to care
          for_ (desktops V.!? deskOld) $ \DeskItemHandle{addRmWinItem} -> do
            addRmWinItem winView windowId WinRemove
          -- For now, let's not care about out of bounds from new windows.
          -- That is likely a sync issue, so it needs proper logging later.
          for_ (desktops V.!? deskNew) $ \DeskItemHandle{addRmWinItem} -> do
            addRmWinItem winView windowId (WinAdd (curOrders M.!?))

-- WinAdd parameter is for ordering
data DeskWinMod = WinRemove | WinAdd (Window -> Maybe Int)
data DeskItemHandle = DeskItemHandle
  { updateDeskItem :: DesktopStat -> IO ()
  , addRmWinItem :: View.WinItem -> Window -> DeskWinMod -> IO ()
  , reorderWinItems :: (Window -> Maybe Int) -> (Window -> Maybe WinItemHandle) -> IO ()
  }

{-
data DeskItemState = DeskItemState
  { deskStat :: !DesktopStat
  , deskWindows :: !(V.Vector Window)
  }
-}

deskItemMake :: DesktopSetup -> DesktopStat -> View.DeskItem -> PulpIO DeskItemHandle
deskItemMake DesktopSetup{..} initStat view = withRunInIO $ \_unlift -> do
  creates <$> newIORef initStat <*> newIORef V.empty
  where
    creates statRef curWindows = DeskItemHandle{..}
      where
        updateDeskItem deskStat@DesktopStat{..} = do
          View.deskItemCtrl view (View.DeskLabelName $ desktopLabeling desktopName)
          View.widgetUpdateClass (View.deskItemWidget view) deskCssClass [desktopState]
          writeIORef statRef deskStat
          updateVisible curWindows

        -- TODO How to on window destroy?
        addRmWinItem winView windowId = \case
          WinRemove -> do
            View.deskItemCtrl view (View.RemoveWinItem winView)
            modifyIORef' curWindows (V.filter (/= windowId))
            updateVisible curWindows
          WinAdd curOrd -> do
            (prev, next) <- V.span (\w -> curOrd w < curOrd windowId) <$> readIORef curWindows
            writeIORef curWindows (prev <> V.singleton windowId <> next)
            View.deskItemCtrl view (View.AddWinItemAt winView $ V.length prev)
            updateVisible curWindows

        reorderWinItems newOrd getHandle = do
          olds <- readIORef curWindows
          let news = V.fromList . sortOn newOrd . V.toList $ olds
          when (news /= olds) $ do
            writeIORef curWindows news
            let newViewOrd =
                  (\WinItemHandle{itemWindowView} -> itemWindowView) <$> V.mapMaybe getHandle news
            View.deskItemCtrl view (View.ReorderWinItems newViewOrd)

        updateVisible curWindows = do
          deskStat <- readIORef statRef
          numWindows <- fromIntegral . V.length <$> readIORef curWindows
          View.deskItemCtrl view (View.DeskVisibility $ showDesktop deskStat numWindows)

newtype WinItemHandle = WinItemHandle
  { itemWindowView :: View.WinItem -- As window can move around, its view should be separately owned.
  }

winItemMake ::
  WindowSetup ->
  GetXIcon ->
  (View.WinItem -> Int -> Int -> IO ()) ->
  PerWinRcvs ->
  View.WinItem ->
  PulpIO WinItemHandle
winItemMake WindowSetup{..} getXIcon onSwitch PerWinRcvs{..} view = do
  -- (-1) is never a valid desktop (means the window is omnipresent)
  liftIO $ registers =<< newIORef (-1)
  where
    registers curDeskRef = do
      killChDesk <- UI.uiTask winDesktop changeDesktop
      killInfo <- UI.uiTask winInfo updateWindow
      -- Frees from desktops so that it is correctly adjusted
      UI.onWidgetDestroy (View.winItemWidget view) (changeDesktop (-1) >> killChDesk >> killInfo)
      pure WinItemHandle{itemWindowView = view}
      where
        changeDesktop newDesk = do
          oldDesk <- atomicModifyIORef' curDeskRef (newDesk,)
          when (newDesk /= oldDesk) $ onSwitch view oldDesk newDesk

        updateWindow winInfo@WindowInfo{..} = do
          View.winItemSetTitle view windowTitle
          windowImgSetter winInfo getXIcon >>= View.winItemSetImg view
          View.widgetUpdateClass (View.winItemWidget view) windowCssClass (S.toList windowState)

{-------------------------------------------------------------------
                          Communication
--------------------------------------------------------------------}

type GetXIcon = IO (Either String [UI.RawIcon])

data DeskVisRcvs = DeskVisRcvs
  { desktopStats :: Task (V.Vector DesktopStat)
  , windowsList :: Task (V.Vector Window)
  , windowActive :: Task (Maybe Window)
  , trackWinInfo :: Window -> IO PerWinRcvs
  , reqActivate :: Window -> IO ()
  , reqToDesktop :: Int -> IO ()
  , winGetIcon :: Window -> GetXIcon
  }

data PerWinRcvs = PerWinRcvs
  { winDesktop :: !(Task Int)
  , winInfo :: !(Task WindowInfo)
  }

-- | Desktop visualizer event handle initiate.
--
-- The widget holds one entire X event loop,
-- so related resources will be disposed of on kill.
deskVisInitiate :: XIO () DeskVisRcvs
deskVisInitiate = do
  rootWin <- xWindow

  desktopStats <- errorAct $ watchXQuery rootWin getDesktopStat pure
  windowsList <- errorAct $ watchXQuery rootWin getAllWindows pure
  windowActive <- errorAct $ watchXQuery rootWin getActiveWindow pure

  trackWinInfo <- xQueryOnce $ \window -> do
    winDesktop <- errorAct $ watchXQuery window getWindowDesktop pure
    winInfo <- errorAct $ watchXQuery window getWindowInfo pure
    pure PerWinRcvs{..}

  reqActivate <- reqActiveWindow True
  reqToDesktop <- reqCurrentDesktop

  winGetIcon <- xQueryOnce $ \window -> do
    first (formatXQError window) <$> xOnWindow window (runXQuery getWindowIcon)

  pure DeskVisRcvs{..}
  where
    onError window err = do
      liftIO (fail $ formatXQError window err)
    errorAct act = do
      window <- xWindow
      act >>= either (onError window) pure
