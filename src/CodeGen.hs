module CodeGen
  ( genConstant
  , genFunction
  , genModule
  )
where

import           Control.Monad                  ( forM
                                                , forM_
                                                , when
                                                , unless
                                                , filterM
                                                )
import           Data.List                      ( nub )
import           Data.Maybe                     ( fromJust
                                                , fromMaybe
                                                , mapMaybe
                                                , isNothing
                                                )
import           Data.Monoid                    ( (<>) )
import qualified Data.Map                      as M
import qualified Data.Text                     as T
import           Data.Text                      ( Text )

import           API
import           Constant                       ( genConstant )
import           EnumFlags                      ( genEnum
                                                , genFlags
                                                )
import           Fixups                         ( dropMovedItems
                                                , guessPropertyNullability
                                                , detectGObject
                                                , dropDuplicatedFields
                                                , checkClosureDestructors
                                                )
import           GObject
import           Method                         ( genMethod )
import           Haddock                        ( deprecatedPragma
                                                , addSectionDocumentation
                                                , writeHaddock
                                                , RelativeDocPosition
                                                  ( DocBeforeSymbol
                                                  )
                                                )
import           Properties                     ( genInterfaceProperties
                                                , genObjectProperties
                                                )
import           Struct                         ( extractCallbacksInStruct
                                                , fixAPIStructs
                                                , ignoreStruct
                                                , genZeroStruct
                                                , genZeroUnion
                                                , genWrappedPtr
                                                )
import           Code
import           Callable                       ( genCCallableWrapper
                                                , callableOCamlTypes
                                                )
import           Inheritance                    ( instanceTree )
import           Signal                         ( genSignal
                                                , genGSignal
                                                )
import           SymbolNaming                   ( upperName
                                                , submoduleLocation
                                                , lowerName
                                                , camelCaseToSnakeCase
                                                , hyphensToUnderscores
                                                , escapeOCamlReserved
                                                )
import           Type
import           Debug.Trace


genFunction :: Name -> Function -> CodeGen ()
genFunction n (Function symbol fnMovedTo callable) =
    -- Only generate the function if it has not been moved.
  when (Nothing == fnMovedTo) $ group $ do
    line $ "-- function " <> symbol
    handleCGExc
      (\e -> line
        (  "(* Could not generate function "
        <> symbol
        <> " *)\n(* Error was : "
        <> describeCGError e
        <> " *)"
        )
      )
      (do
        genCCallableWrapper n symbol callable
        export (NamedSubsection MethodSection $ lowerName n) (lowerName n)
      )

genBoxedObject :: Name -> Text -> CodeGen ()
genBoxedObject n typeInit = do
  let name'       = upperName n
      get_type_fn = "c_" <> typeInit

  group $ do
    line
      $  "foreign import ccall \""
      <> typeInit
      <> "\" "
      <> get_type_fn
      <> " :: "
    indent $ line "IO GType"
  group $ do
    line $ "instance BoxedObject " <> name' <> " where"
    indent $ line $ "boxedType _ = " <> get_type_fn

  line $ "instance BoxedObject " <> name' <> " where"

-- | Generate wrapper for structures.
genStruct :: Name -> Struct -> CodeGen ()
genStruct n s = unless (ignoreStruct n s) $ do
  let name' = upperName n
  -- writeHaddock DocBeforeSymbol "Memory-managed wrapper type."

  -- addSectionDocumentation ToplevelSection (structDocumentation s)

  line "type t"

  hline
    $  "#define "
    <> (namespace n <> name n)
    <> "_val(val) (("
    <> (namespace n <> name n)
    <> "*) MLPointer_val(val))"

  -- if structIsBoxed s
  --   then traceShowM $ "Struct " <> show n <> " is boxed"
  --   else traceShowM $ "Struct " <> show n <> " not boxed"

  -- if structIsBoxed s
  --   then genBoxedObject n (fromJust $ structTypeInit s)
  --   else genWrappedPtr n (structAllocationInfo s) (structSize s)

  -- exportDecl (name' <> "(..)")

  -- -- Generate a builder for a structure filled with zeroes.
  -- genZeroStruct n s

  -- noName name'

  -- -- Generate code for fields.
  -- genStructOrUnionFields n (structFields s)

  -- -- Methods
  -- _methods <- forM (structMethods s) $ \f -> do
  --   let mn = methodName f
  --   isFunction <- symbolFromFunction (methodSymbol f)
  --   if not isFunction
  --     then handleCGExc
  --       (\e ->
  --         line
  --             (  "(* Could not generate method "
  --             <> name'
  --             <> "::"
  --             <> name mn
  --             <> " *)\n"
  --             <> "(* Error was : "
  --             <> describeCGError e
  --             <> " *)"
  --             )
  --           >> return Nothing
  --       )
  --       (genMethod n f >> return (Just (n, f)))
  --     else return Nothing

  return ()

-- | Generated wrapper for unions.
genUnion :: Name -> Union -> CodeGen ()
genUnion n u = do
  let name' = upperName n

  writeHaddock DocBeforeSymbol "Memory-managed wrapper type."

  addSectionDocumentation ToplevelSection (unionDocumentation u)

  if unionIsBoxed u
    then genBoxedObject n (fromJust $ unionTypeInit u)
    else genWrappedPtr n (unionAllocationInfo u) (unionSize u)

  exportDecl (name' <> "(..)")

  -- Generate a builder for a structure filled with zeroes.
  genZeroUnion n u

  -- Generate code for fields.
  -- genStructOrUnionFields n (unionFields u)

  -- Methods
  _methods <- forM (unionMethods u) $ \f -> do
    let mn = methodName f
    isFunction <- symbolFromFunction (methodSymbol f)
    if not isFunction
      then handleCGExc
        (\e ->
          line
              (  "(* Could not generate method "
              <> name'
              <> "::"
              <> name mn
              <> " *)\n"
              <> "(* Error was : "
              <> describeCGError e
              <> " *)"
              )
            >> return Nothing
        )
        (genMethod n f >> return (Just (n, f)))
      else return Nothing

  return ()

genGObjectCasts :: Name -> CodeGen ()
genGObjectCasts (Name nspace n) = do
  let upperObjName = T.toUpper (nspace <> "_" <> camelCaseToSnakeCase n)
  hline
    $  "#define "
    <> nspace
    <> n
    <> "_val("
    <> "val) check_cast("
    <> upperObjName
    <> ", val)"

  hline $ "#define Val_" <> nspace <> n <> " Val_GAnyObject"
  -- hline
  --   $  "#define Val_"
  --   <> nspace
  --   <> n
  --   <> "("
  --   <> T.toLower n
  --   <> ") ((value) "
  --   <> T.toLower n
  --   <> ")"

  addCDep $ nspace <> n


isSetterOrGetter :: Object -> Method -> Bool
isSetterOrGetter o m =
  let props = objProperties o
  in  let propNames = map (hyphensToUnderscores . propName) props
      in  let mName = name $ methodName m
          in  ("get" `T.isPrefixOf` mName || "set" `T.isPrefixOf` mName)
                && any (`T.isSuffixOf` mName) propNames

genSignalClass :: Name -> Object -> CodeGen ()
genSignalClass n o = do
  let objectName = name n
      ocamlName  = camelCaseToSnakeCase objectName

  gline $ "class " <> ocamlName <> "_signals obj = object (self)"

  parents <- instanceTree n

  case name $ head parents of
    "Container" -> gline "  inherit GContainer.container_signals_impl obj"
    "Widget"    -> gline "  inherit GObj.widget_signals_impl obj"
    "Object"    -> gline "  inherit [_] GObj.gobject_signals obj"
    parent      -> do
      let ocamlParentName = camelCaseToSnakeCase parent
      gline
        $  "  inherit "
        <> parent
        <> "G."
        <> ocamlParentName
        <> "_signals obj"

  forM_ (objSignals o) $ \s -> genGSignal s n
  gline "end"
  gblank

-- | Wrap a given Object. We enforce that every Object that we wrap is a
-- GObject. This is the case for everything except the ParamSpec* set
-- of objects, we deal with these separately.
genObject :: Name -> Object -> CodeGen ()
genObject n o = -- do
  -- if name n `notElem` ["Button", "ToggleButton", "RadioButton", "Toolbar", "ColorButton", "FontButton", "Range"] then
  if namespace n
     /=        "Gtk"
     ||        name n
     `notElem` [ "Bin"
               , "Button"
               , "CheckButton"
               , "ToggleButton"
               , "RadioButton"
               , "Misc"
               , "Label"
               , "Entry"
               , "ActionBar"
               , "MenuShell"
               , "RadioMenuItem"
               , "CheckMenuItem"
               , "Menu"
               , "MenuItem"
               , "Adjustment"
               , "Alignment"
               , "AppChooserButton"
               , "ComboBox"
              --  , "AccelMap"
              --  , "Layout"
              --  , "Container"
              --  , "Window"
              --  , "Image"
              --  , "Range"
               ]
  then
    do
      commentLine "Ignored: I'm generating only button and range"
      parents <- instanceTree n
      let objectName = name n
          ocamlName  = escapeOCamlReserved $ camelCaseToSnakeCase objectName
          parent     = head parents

      let parentType =
            case (name parent == "Object", namespace parent == "Gtk") of
              (True, _   ) -> "`giu"
              (_   , True) -> "" <> name parent <> ".t"
              _            -> "`" <> camelCaseToSnakeCase (name parent)
      line $ "type t = [" <> parentType <> " | `" <> ocamlName <> "]"

      when (objectName == "Widget") $ do
        gline "class type widget_o = object"
        gline "  method as_widget : Widget.t Gobject.obj"
        gline "end"

      genGObjectCasts n
  else
    do
      let name' = upperName n
      let t     = TInterface n
      isGO <- isGObject t

      if not isGO
        then
          line
          $  "-- APIObject \""
          <> name'
          <> "\" does not descend from GObject, it will be ignored."
        else do
        -- writeHaddock DocBeforeSymbol ("Memory-managed wrapper type.")
        -- exportDecl (name' <> "(..)")

        -- addSectionDocumentation ToplevelSection (objDocumentation o)

        -- Type safe casting to parent objects, and implemented interfaces.
          parents <- instanceTree n
          let nspace               = namespace n
              objectName           = name n
              ocamlName            = camelCaseToSnakeCase objectName
              namespacedOcamlName  = camelCaseToSnakeCase $ nspace <> objectName
              parent               = head parents
              ocamlParentName      = camelCaseToSnakeCase $ name parent
              namespacedParentName = case name parent of
                "Container" -> "['a] GContainer.container_impl"
                "Widget"    -> "['a] GObj.widget_impl"
                "Object"    -> "GObj.gtkobj"
                _           -> name parent <> "G." <> ocamlParentName <> "_skel"

          genGObjectCasts n

          cline
            $  "CAMLprim value ml_"
            <> namespacedOcamlName
            <> "_init(value unit) {"
          cline $ "    GType t = " <> namespacedOcamlName <> "_get_type();"
          cline "    return Val_GType(t);"
          cline "}"

          gline "open GtkSignal"
          gline "open Gobject"
          gline "open Data"
          gblank
          gline $ "open " <> objectName
          gblank

          gline $ "class type " <> ocamlName <> "_o = object"
          gline $ "  method as_" <> ocamlName <> " : t obj"
          gline "end"
          gblank

          gline $ "class " <> ocamlName <> "_skel obj = object (self)"
          gline $ "  inherit " <> namespacedParentName <> " obj"
          gline $ "  method as_" <> ocamlName <> " = (obj :> t obj)"

          line "open Gobject"
          line "open Data"
          blank
          line "open Gtk"
          blank

          group $ do
            line
              $  "external ml_"
              <> namespacedOcamlName
              <> "_init : unit -> unit = \"ml_"
              <> namespacedOcamlName
              <> "_init\""
            line $ "let () = ml_" <> namespacedOcamlName <> "_init ()"

          let parentType =
                case (name parent == "Object", namespace parent == "Gtk") of
                  (True, _   ) -> "`giu"
                  (_   , True) -> "" <> name parent <> ".t"
                  _            -> "`" <> camelCaseToSnakeCase (name parent)
          line $ "type t = [" <> parentType <> " | `" <> ocamlName <> "]"
          blank

          group $ do
            genObjectProperties n o
            gblank

          unless (null $ objSignals o) $ group $ do
            line "module S = struct"
            indent $ do
              line $ "open " <> nspace <> "Signal"
              forM_ (objSignals o) $ \s -> genSignal s n

            line "end"

          group
            $  line
            $  "let cast w : "
            <> "t obj = try_cast w \""
            <> nspace
            <> objectName
            <> "\""

          group
            $  line
            $  "let create pl : "
            <> "t obj = GtkObject.make \""
            <> nspace
            <> objectName
            <> "\" pl"

          -- Methods
          gline "  (* Methods *)"
          let methods  = objMethods o
          let methods' = filter (not . isSetterOrGetter o) methods

          forM_ methods' $ \f -> do
            let mn = methodName f
            handleCGExc
              (\e -> line
                (  "(* Could not generate method "
                <> name'
                <> "::"
                <> name mn
                <> " *)\n"
                <> "(* Error was : "
                <> describeCGError e
                <> " *)"
                )
              )
              (genMethod n f)
          gline "end"
          gblank

          genSignalClass n o

          gline $ "class " <> ocamlName <> " obj = object (self)"
          gline $ "  inherit " <> ocamlName <> "_skel obj"
          unless (null $ objSignals o)
            $  group
            $  gline
            $  "  method connect = new "
            <> ocamlName
            <> "_signals obj"
          gline "end"

          if "Widget" `elem` map name parents
            then do
              gline "let pack_return create p ?packing ?show () ="
              gline "  GObj.pack_return (create p) ~packing ~show"

              gline $ "let " <> ocamlName <> " = "
              gline $ "  " <> objectName <> ".make_params [] ~cont:("
              gline
                $  "    pack_return (fun p -> new "
                <> ocamlName
                <> " ("
                <> objectName
                <> ".create p)))"
            else do
              gline $ "let " <> ocamlName <> " = "
              gline
                $  "  "
                <> objectName
                <> ".make_params [] ~cont:(fun p -> new "
                <> ocamlName
                <> " ("
                <> objectName
                <> ".create p))"

genInterface :: Name -> Interface -> CodeGen ()
genInterface n iface = do
  let name' = upperName n

  line $ "-- interface " <> name' <> " "
  writeHaddock DocBeforeSymbol ("Memory-managed wrapper type.")
  deprecatedPragma name' $ ifDeprecated iface

  exportDecl (name' <> "(..)")

  addSectionDocumentation ToplevelSection (ifDocumentation iface)

  forM_ (ifSignals iface) $ \s -> handleCGExc
    ( commentLine
    . (T.concat
        [ "Could not generate signal "
        , name'
        , "::"
        , sigName s
        , " *)\n"
        , "(* Error was : "
        ] <>
      )
    . describeCGError
    )
    (genSignal s n)

  isGO <- apiIsGObject n (APIInterface iface)
  if isGO
    then do
      let cn_ = fromMaybe (error "GObject derived interface without a type!")
                          (ifTypeInit iface)
      gobjectPrereqs <- filterM nameIsGObject (ifPrerequisites iface)
      allParents     <- forM gobjectPrereqs $ \p -> (p :) <$> instanceTree p
      let uniqueParents = nub (concat allParents)
      -- genGObjectCasts n cn_ uniqueParents

      genInterfaceProperties n iface
    else group $ do
      writeHaddock DocBeforeSymbol
                   ("Type class for types which implement `" <> name' <> "`.")

      -- Create the IsX constraint. We cannot simply say
      --
      -- > type IsX o = (ManagedPtrNewtype o, O.IsDescendantOf X o)
      --
      -- since we sometimes need to refer to @IsX@ itself, without
      -- applying it. We instead use the trick of creating a class with
      -- a universal instance.

      genWrappedPtr n (ifAllocationInfo iface) 0

      unless (null . ifProperties $ iface) $ group $ commentLine
        "XXX Skipping property generation for non-GObject interface"


  forM_ (ifMethods iface) $ \f -> do
    let mn = methodName f
    isFunction <- symbolFromFunction (methodSymbol f)
    unless isFunction $ handleCGExc
      (\e -> line
        (  "(* Could not generate method "
        <> name'
        <> "::"
        <> name mn
        <> " *)\n"
        <> "(* Error was : "
        <> describeCGError e
        <> " *)"
        )
      )
      (genMethod n f)

-- Some type libraries include spurious interface/struct methods,
-- where a method Mod.Foo::func also appears as an ordinary function
-- in the list of APIs. If we find a matching function (without the
-- "moved-to" annotation), we don't generate the method.
--
-- It may be more expedient to keep a map of symbol -> function.
symbolFromFunction :: Text -> CodeGen Bool
symbolFromFunction sym = any (hasSymbol sym . snd) . M.toList <$> getAPIs
 where
  hasSymbol sym1 (APIFunction Function { fnSymbol = sym2, fnMovedTo = movedTo })
    = sym1 == sym2 && isNothing movedTo
  hasSymbol _ _ = False

-- genAPI :: Name -> API -> CodeGen ()
-- genAPI n (APIConst c) = genConstant n c
-- genAPI n (APIFunction f) = genFunction n f
-- genAPI n (APIEnum e) = genEnum n e
-- genAPI n (APIFlags f) = genFlags n f
-- genAPI n (APICallback c) = genCallback n c
-- genAPI n (APIStruct s) = genStruct n s
-- genAPI n (APIUnion u) = genUnion n u
-- genAPI n (APIObject o) = genObject n o
-- genAPI n (APIInterface i) = genInterface n i

genAPI :: Name -> API -> CodeGen ()
genAPI _n (APIConst     _c) = return ()
genAPI _n (APIFunction  _f) = return ()
genAPI n  (APIEnum      e ) = genEnum n e
genAPI n  (APIFlags     f ) = genFlags n f
genAPI _n (APICallback  _c) = return ()
genAPI n  (APIStruct    s ) = genStruct n s
genAPI _n (APIUnion     _u) = return ()
genAPI n  (APIObject    o ) = genObject n o
genAPI _n (APIInterface _i) = return ()

-- | Generate the code for a given API in the corresponding module.
genAPIModule :: Name -> API -> CodeGen ()
genAPIModule n api = submodule (submoduleLocation n api) $ genAPI n api

genModule' :: M.Map Name API -> CodeGen ()
genModule' apis = do
  mapM_ (uncurry genAPIModule)
            -- We provide these ourselves
    $ filter
        ( (`notElem` [ Name "GLib"    "Array"
                     , Name "GLib"    "Error"
                     , Name "GLib"    "HashTable"
                     , Name "GLib"    "List"
                     , Name "GLib"    "SList"
                     , Name "GLib"    "Variant"
                     , Name "GObject" "Value"
                     , Name "GObject" "Closure"
                     ]
          )
        . fst
        )
    $ mapMaybe (traverse dropMovedItems)
            -- Some callback types are defined inside structs
    $ map fixAPIStructs
            -- Try to guess nullability of properties when there is no
            -- nullability info in the GIR.
    $ map guessPropertyNullability
            -- Not every interface providing signals or properties is
            -- correctly annotated as descending from GObject, fix this.
    $ map detectGObject
            -- Some APIs contain duplicated fields by mistake, drop
            -- the duplicates.
    $ map dropDuplicatedFields
            -- Make sure that every argument marked as being a
            -- destructor for a user_data argument has an associated
            -- user_data argument.
    $ map checkClosureDestructors
    $ M.toList
    $ apis

  -- Make sure we generate a "Callbacks" module, since it is imported
  -- by other modules. It is fine if it ends up empty.
  submodule "Callbacks" (return ())

genModule :: M.Map Name API -> CodeGen ()
genModule apis = do
  -- Reexport Data.GI.Base for convenience (so it does not need to be
  -- imported separately).
  -- line "import Data.GI.Base"
  -- exportModule "Data.GI.Base"

  -- Some API symbols are embedded into structures, extract these and
  -- inject them into the set of APIs loaded and being generated.
  let embeddedAPIs =
        (M.fromList . concatMap extractCallbacksInStruct . M.toList) apis
  allAPIs <- getAPIs
  recurseWithAPIs (M.union allAPIs embeddedAPIs)
                  (genModule' (M.union apis embeddedAPIs))
