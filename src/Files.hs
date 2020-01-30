module Files
    ( excludeFiles
    , genFiles
    )
where

import           Data.Text                      ( Text )
import           Data.Set                       ( Set )
import qualified Data.Set                      as S

import           API                            ( Name(..) )

excludeFiles :: Set Name
excludeFiles = S.fromList
    [ Name "Gtk"   "HeaderBarAccessible"
    , Name "Pango" "Engine"
    , Name "Pango" "FontsetSimple"
    ]

genFiles :: Set Name
genFiles = S.fromList
    [ Name "Gtk" "Bin"
    , Name "Gtk" "Button"
    , Name "Gtk" "CheckButton"
    , Name "Gtk" "ToggleButton"
    , Name "Gtk" "RadioButton"
    , Name "Gtk" "Misc"
    , Name "Gtk" "Label"
    , Name "Gtk" "Entry"
    , Name "Gtk" "ActionBar"
    , Name "Gtk" "MenuShell"
    , Name "Gtk" "RadioMenuItem"
    , Name "Gtk" "CheckMenuItem"
    , Name "Gtk" "Menu"
    , Name "Gtk" "MenuItem"
    , Name "Gtk" "Adjustment"
    , Name "Gtk" "Alignment"
    , Name "Gtk" "AppChooserButton"
    , Name "Gtk" "ComboBox"
--  , Name "Gtk" "AccelMap"
--  , Name "Gtk" "Layout"
--  , Name "Gtk" "Container"
--  , Name "Gtk" "Window"
--  , Name "Gtk" "Image"
--  , Name "Gtk" "Range"
    ]
