{-# LANGUAGE OverloadedStrings #-}

module Bar where

import Control.Monad
import Data.Map qualified as M
import Data.Maybe
import GI.Gdk
import GI.Gtk hiding (main)
import System.FilePath
import System.Taffybar
import System.Taffybar.Context (TaffyIO)
import System.Taffybar.Information.CPU
import System.Taffybar.Information.Memory
import System.Taffybar.SimpleConfig hiding
  ( barPadding,
  )
import System.Taffybar.Widget
import System.Taffybar.Widget.Generic.Icon
import System.Taffybar.Widget.Generic.PollingBar
import Text.Printf
import XMonad.ManageHook
import XMonad.Util.Run

runOnClick :: IO () -> EventButton -> IO Bool
runOnClick act btn = do
  b <- getEventButtonButton btn
  True <$ when (b == 1) act

batWidget :: TaffyIO Widget
batWidget = do
  -- The display
  disp <- batteryIconNew

  -- Add button events
  ev <- eventBoxNew
  containerAdd ev disp
  onWidgetButtonReleaseEvent ev $ runOnClick $ safeSpawn "gnome-control-center" ["power"]

  widgetShowAll ev
  toWidget ev

cpuCallback :: IO Double
cpuCallback = do
  (_, _, totalLoad) <- cpuLoad
  return totalLoad

cpuWidget :: FilePath -> TaffyIO Widget
cpuWidget home = do
  -- The display
  disp <- pollingIconImageWidgetNew (cpuN 0) 0.1 $ do
    cpu <- cpuCallback
    pure (cpuN . round $ cpu * 5)

  -- Add button events
  ev <- eventBoxNew
  containerAdd ev disp
  onWidgetButtonReleaseEvent ev $ runOnClick $ safeSpawn "gnome-system-monitor" ["-r"]

  widgetShowAll ev
  toWidget ev
  where
    cpuN :: Int -> FilePath
    cpuN n = home </> "asset" </> "icons" </> printf "cpu%d.png" n

memCallback :: IO Double
memCallback = memoryUsedRatio <$> parseMeminfo

memWidget :: FilePath -> TaffyIO Widget
memWidget xmDir = do
  -- Foreground and the Bar
  fg <- iconImageWidgetNew memN
  bar <- pollingBarNew memCfg 0.5 memCallback
  barCtxt <- widgetGetStyleContext bar
  styleContextAddClass barCtxt "mem-bar"

  -- Overlay bg image above memory bar
  wid <- overlayNew
  containerAdd wid bar
  overlayAddOverlay wid fg

  -- Add button events
  ev <- eventBoxNew
  containerAdd ev wid
  onWidgetButtonReleaseEvent ev $ runOnClick $ safeSpawn "gnome-system-monitor" ["-r"]

  widgetShowAll ev
  toWidget ev
  where
    memN = xmDir </> "asset" </> "icons" </> "ram.png"
    memCfg =
      (defaultBarConfig $ const (0.1, 0.6, 0.9)) {barWidth = 9, barPadding = 0}

workspaceMaps :: M.Map String String
workspaceMaps =
  M.fromList
    [ ("main", "\xe3af"),
      ("docs", "\xf0c7"),
      ("code", "\xf121"),
      ("term", "\xf120"),
      ("chat", "\xf4ad"),
      ("pics", "\xf03e")
    ]

startBar :: FilePath -> IO ()
startBar home =
  startTaffybar $
    toTaffyConfig
      defaultSimpleTaffyConfig
        { startWidgets = [workspaces],
          centerWidgets = [clock],
          endWidgets = [sniTrayNew, memWidget home, cpuWidget home, batWidget],
          barPosition = Top,
          barHeight = read "ExactSize 45",
          cssPaths = [home </> "styles" </> "taffybar.css"]
        }
  where
    clock =
      textClockNewWith
        defaultClockConfig
          { clockFormatString = "%a %b %_d %H:%M %p"
          }
    getName n = fromMaybe n $ workspaceMaps M.!? n
    workspaces =
      workspacesNew
        defaultWorkspacesConfig
          { showWorkspaceFn = hideEmpty <&&> ((/= "NSP") . workspaceName),
            labelSetter = pure . getName . workspaceName
          }
