module Main where

import           Control.Monad                  ( forM_ )
import           Data.Text                      ( Text )
import qualified Data.Text                     as T

import           System.Environment
import           System.Exit

import           GI                             ( genBindings
                                                , Library(..)
                                                )

gobjectLib :: Library
gobjectLib = Library { name          = "GObject"
                     , version       = "2.0"
                     , overridesFile = Just "overrides/GObject.overrides"
                     }

atkLib :: Library
atkLib = Library { name          = "Atk"
                 , version       = "1.0"
                 , overridesFile = Just "overrides/Atk.overrides"
                 }

gtkLib :: Library
gtkLib = Library { name          = "Gtk"
                 , version       = "3.0"
                 , overridesFile = Just "overrides/Gtk.overrides"
                 }

gdkLib :: Library
gdkLib = Library { name          = "Gdk"
                 , version       = "3.0"
                 , overridesFile = Just "overrides/Gdk.overrides"
                 }

gdkPixbufLib :: Library
gdkPixbufLib = Library { name          = "GdkPixbuf"
                       , version       = "2.0"
                       , overridesFile = Just "overrides/GdkPixbuf.overrides"
                       }

pangoLib :: Library
pangoLib = Library { name          = "Pango"
                   , version       = "1.0"
                   , overridesFile = Just "overrides/Pango.overrides"
                   }

cairoLib :: Library
cairoLib = Library { name          = "cairo"
                   , version       = "1.0"
                   , overridesFile = Just "overrides/cairo.overrides"
                   }

glibLib :: Library
glibLib = Library { name          = "GLib"
                  , version       = "2.0"
                  , overridesFile = Just "overrides/GLib.overrides"
                  }

gioLib :: Library
gioLib = Library { name          = "Gio"
                 , version       = "2.0"
                 , overridesFile = Just "overrides/Gio.overrides"
                 }

gtkSourceLib :: Library
gtkSourceLib = Library { name          = "GtkSource"
                       , version       = "3.0"
                       , overridesFile = Just "overrides/GtkSource.overrides"
                       }

parseArg :: String -> IO Library
parseArg "atk"       = return atkLib
parseArg "gtk"       = return gtkLib
parseArg "gdk"       = return gdkLib
parseArg "gdkpixbuf" = return gdkPixbufLib
parseArg "pango"     = return pangoLib
parseArg "cairo"     = return cairoLib
parseArg "glib"      = return glibLib
parseArg "gobject"   = return gobjectLib
parseArg "gio"       = return gioLib
parseArg "gtksource" = return gtkSourceLib
parseArg "-h"        = printUsage >> exitSuccess
parseArg "-v"        = printVersion >> exitSuccess
parseArg _           = printUsage >> exitSuccess

main :: IO ()
main = do
  let verbose = False
  args <- getArgs
  case args of
    [] -> printUsage >> exitSuccess
    _  -> do
      libs <- mapM parseArg args
      forM_ libs (genBindings verbose)

printUsage :: IO ()
printUsage =
  putStrLn
    "Usage: ocaml-gi-gtk [-h] [-v] [atk, gdk, gdkpixbuf, pango, cairo, gtk, gio, glib, gobject, gtksource]"

printVersion :: IO ()
printVersion = putStrLn "ocaml-gi-gtk 0.1"
