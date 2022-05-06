-- | Displaying certain selections
module Selects
  ( actSystemCtl,
    actGotoWindow,
    TSConfig (..),
    GSConfig (..),
  )
where

import Data.Foldable
import System.Exit
import XMonad
import XMonad.Actions.GridSelect
import XMonad.Actions.TreeSelect
import XMonad.Util.Run

selectEnum :: (Show a, Enum a, Bounded a) => TSConfig a -> X (Maybe a)
selectEnum cfg = treeselect cfg $ pure . nodeOf <$> [minBound .. maxBound]
  where
    nodeOf en = TSNode (show en) "" en

data SystemCtl = Recompile | Refresh | Logout | Reboot | PowerOff
  deriving (Show, Enum, Bounded)

actSystemCtl :: TSConfig SystemCtl -> Directories -> X ()
actSystemCtl cfg _dirs = withDisplay $ \disp -> do
  -- TODO Improve (or start GTK UI)
  let dispW = fromIntegral $ displayWidth disp (defaultScreen disp)
      dispH = fromIntegral $ displayHeight disp (defaultScreen disp)
      ctlW = 250
      ctlH = 60
  ctl <-
    selectEnum
      cfg
        { ts_node_width = ctlW,
          ts_node_height = ctlH,
          ts_originX = (dispW - ctlW) `div` 2,
          ts_originY = (dispH - ctlH * fromEnum @SystemCtl maxBound) `div` 2
        }
  for_ ctl $ \case
    -- TODO Using terminal to display is lame
    Recompile -> safeSpawn "gnome-terminal" ["--class=term-float", "--", "xmonad-manage", "build", "pulpmonad"]
    -- TODO Restart routine
    Refresh -> safeSpawn "xmonad" ["--restart"]
    Logout -> io $ exitWith ExitSuccess
    Reboot -> safeSpawn "systemctl" ["reboot"]
    PowerOff -> safeSpawn "systemctl" ["poweroff"]

actGotoWindow :: GSConfig Window -> X ()
actGotoWindow cfg = goToSelected cfg
