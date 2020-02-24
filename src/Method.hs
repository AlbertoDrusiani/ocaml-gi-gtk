module Method
  ( genMethod
  , typeRepsToMethodArgs
  , methodInTypeShow
  , methodOutTypeShow
  , MethodArgs
  , MethodInArg(..)
  , MethodOutArg
  )
where

import           GObject
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Maybe                     ( mapMaybe )
import           Control.Monad                  ( when
                                                , forM
                                                , unless
                                                )

import           API                            ( Arg(..)
                                                , Callable(..)
                                                , Direction(..)
                                                , Name(..)
                                                , Method(..)
                                                , MethodType(..)
                                                , Type(..)
                                                , API(..)
                                                , Object(..)
                                                , Property(..)
                                                )
import           Callable                       ( genCCallableWrapper
                                                , callableOCamlTypes
                                                )
import           Code                           ( CodeGen
                                                , ExcCodeGen
                                                , gline
                                                , getFreshTypeVariable
                                                , currentNS
                                                , findAPIByName
                                                , instanceTree
                                                )
import           Naming
import           QualifiedNaming                ( nsOCamlClass )
import           TypeRep
import           Util                           ( noLast )


data MethodInArg = BasicIn Text Text
                 | ClassType Bool Text Name
                 | NonGtkClassType Bool Text Text
  deriving (Show)

data MethodOutArg = BasicOut Text
                  | Class Bool Name
                  | NonGtkClass Bool Text Text
  deriving (Show)

type MethodArgs = (MethodInArg, [MethodInArg], MethodOutArg)

typeRepsToMethodArgs :: [TypeRep] -> CodeGen (Maybe MethodArgs)
typeRepsToMethodArgs []                    = return Nothing
typeRepsToMethodArgs xs@(h : typeRepsTail) = do
  currNS  <- currentNS
  headArg <- methodInTypeShow currNS h
  inArgs' <- mapM (methodInTypeShow currNS) (noLast typeRepsTail)
  let inArgs = case headArg of
        ClassType _ _ _           -> inArgs'
        t@(BasicIn _ _          ) -> t : inArgs'
        t@(NonGtkClassType _ _ _) -> t : inArgs'
  let retTypeRep = last xs -- This last is safe
  retArg <- methodOutTypeShow currNS retTypeRep
  return $ Just (headArg, inArgs, retArg)

methodInTypeShow :: Text -> TypeRep -> CodeGen MethodInArg
methodInTypeShow _currNS (OptionCon (ObjCon (TypeVarCon tvar (RowCon More (PolyCon (NameCon n@(Name "Gtk" _)))))))
  = return $ ClassType True tvar n
methodInTypeShow currNS t@(OptionCon (ObjCon (TypeVarCon tvar (RowCon More (PolyCon (NameCon _))))))
  = return $ NonGtkClassType True tvar $ methodTypeShow currNS t
methodInTypeShow _currNS (ObjCon (TypeVarCon tvar (RowCon More (PolyCon (NameCon n@(Name "Gtk" _))))))
  = return $ ClassType False tvar n
methodInTypeShow currNS t@(ObjCon (TypeVarCon tvar (RowCon More (PolyCon (NameCon _)))))
  = return $ NonGtkClassType False tvar $ methodTypeShow currNS t
methodInTypeShow currNS t = do
  tvar <- getFreshTypeVariable
  return $ BasicIn tvar $ methodTypeShow currNS t

methodOutTypeShow :: Text -> TypeRep -> CodeGen MethodOutArg
methodOutTypeShow _currNS (OptionCon (ObjCon (TypeVarCon _tvar (RowCon Less (PolyCon (NameCon n@(Name "Gtk" _)))))))
  = return $ Class True n
methodOutTypeShow currNS t@(OptionCon (ObjCon (TypeVarCon tvar (RowCon Less (PolyCon (NameCon _))))))
  = return $ NonGtkClass True tvar (methodTypeShow currNS t)
methodOutTypeShow _currNS (ObjCon (TypeVarCon _tvar (RowCon Less (PolyCon (NameCon n@(Name "Gtk" _))))))
  = return $ Class False n
methodOutTypeShow currNS t@(ObjCon (TypeVarCon tvar (RowCon Less (PolyCon (NameCon _)))))
  = return $ NonGtkClass False tvar (methodTypeShow currNS t)
methodOutTypeShow currNS t = return $ BasicOut $ methodTypeShow currNS t

addOption :: Bool -> Text -> Text
addOption False t = t
addOption True  t = t <> " option"

showMethodInArg :: MethodInArg -> CodeGen Text
showMethodInArg (BasicIn _ t                      ) = return t
showMethodInArg (NonGtkClassType _isOption _tvar t) = return t
showMethodInArg (ClassType       isOption  tvar  n) = do
  currNS <- currentNS
  return
    $  addOption isOption
    $  "("
    <> nsOCamlO currNS n
    <> " as '"
    <> tvar
    <> ")"

showMethodOutArg :: MethodOutArg -> CodeGen Text
showMethodOutArg (BasicOut t                   ) = return t
showMethodOutArg (NonGtkClass _isOption _tvar t) = return t
showMethodOutArg (Class isOption n             ) = do
  api         <- findAPIByName n
  ocamlClass' <- nsOCamlClass n
  let
    ocamlClass = case api of
      APIObject    _ -> ocamlClass'
      APIInterface _ -> ocamlClass' <> "_skel"
      _ ->
        error
          "error in (showMethodOutArg): this name can only be an Object or an Interface"
  return $ addOption isOption ocamlClass

tVarClassType :: MethodInArg -> Maybe Text
tVarClassType (ClassType       _ var _) = Just var
tVarClassType (NonGtkClassType _ var _) = Just var
tVarClassType (BasicIn _var _         ) = Nothing

extractClassVars :: MethodArgs -> [Text]
extractClassVars (_, inArgs, NonGtkClass _ tvar _) =
  mapMaybe tVarClassType inArgs ++ [tvar]
extractClassVars (_, inArgs, _) = mapMaybe tVarClassType inArgs

extractVars :: [MethodInArg] -> [Text]
extractVars = concatMap inner
 where
  inner (ClassType       _ var _) = [var]
  inner (NonGtkClassType _ var _) = [var]
  inner (BasicIn var _          ) = [var]

-- | When parsing the GIR file we add the implicit object argument to
-- methods of an object.  Since we are prepending an argument we need
-- to adjust the offset of the length arguments of CArrays, and
-- closure and destroyer offsets.
fixMethodArgs :: Callable -> Callable
fixMethodArgs c = c { args = args'', returnType = returnType' }
 where
  returnType' = fmap fixCArrayLength (returnType c)
  args'       = map (fixDestroyers . fixClosures . fixLengthArg) (args c)
  args''      = fixInstance (head args') : tail args'

  fixLengthArg :: Arg -> Arg
  fixLengthArg arg = arg { argType = fixCArrayLength (argType arg) }

  fixCArrayLength :: Type -> Type
  fixCArrayLength (TCArray zt fixed len t) =
    if len > -1 then TCArray zt fixed (len + 1) t else TCArray zt fixed len t

  fixCArrayLength t = t

  fixDestroyers :: Arg -> Arg
  fixDestroyers arg =
    let destroy = argDestroy arg
    in  if destroy > -1 then arg { argDestroy = destroy + 1 } else arg

  fixClosures :: Arg -> Arg
  fixClosures arg =
    let closure = argClosure arg
    in  if closure > -1 then arg { argClosure = closure + 1 } else arg

  -- We always treat the instance argument of a method as non-null
  -- and "in", even if sometimes the introspection data may say
  -- otherwise.
  fixInstance :: Arg -> Arg
  fixInstance arg = arg { mayBeNull = False, direction = DirectionIn }

-- TODO: This is old code from haskell-gi. For now we're ignoring constructors
--       but this may be useful in the future

-- For constructors we want to return the actual type of the object,
-- rather than a generic superclass (so Gtk.labelNew returns a
-- Gtk.Label, rather than a Gtk.Widget)
fixConstructorReturnType :: Bool -> Name -> Callable -> Callable
fixConstructorReturnType returnsGObject cn c = c { returnType = returnType' }
 where
  returnType' = if returnsGObject then Just (TInterface cn) else returnType c

isMethodAlsoAProp :: Name -> Text -> CodeGen Bool
isMethodAlsoAProp cn mName = do
  api <- findAPIByName cn
  return $ case api of
    APIObject o -> do
      let propNames = hyphensToUnderscores . propName <$> objProperties o
      mName `elem` propNames
    _ -> False

isMethodInParents :: Name -> Text -> CodeGen Bool
isMethodInParents cn mName = do
  parents        <- instanceTree cn
  parentsHasProp <- forM parents $ \parentName -> do
    api <- findAPIByName parentName
    return $ case api of
      APIObject o -> do
        let parentPropNames =
              hyphensToUnderscores . propName <$> objProperties o
            parentPropGetters = ("get_" <>) <$> parentPropNames
            parentPropSetters = ("set_" <>) <$> parentPropNames
            parentPropNames'  = parentPropGetters ++ parentPropSetters
            parentMethodNames = name . methodName <$> objMethods o
            parentNames       = parentPropNames' ++ parentMethodNames
        mName `elem` parentNames
      _ -> False
  return $ True `elem` parentsHasProp

genMethod :: Name -> Method -> ExcCodeGen ()
genMethod cn Method { methodName = mn, methodSymbol = sym, methodCallable = c, methodType = Constructor }
  = when (name mn /= "new") $ do
    returnsGObject <- maybe (return False) isGObject (returnType c)
    let c' = fixConstructorReturnType returnsGObject cn c
    genCCallableWrapper mn sym c'
genMethod cn Method { methodName = mn, methodSymbol = sym, methodCallable = c, methodType = t }
  = do
    isAProp <- isMethodAlsoAProp cn (name mn)
    unless isAProp $ do
      alreadyDefMethod <- isMethodInParents cn (name mn)
      let mName     = escapeOCamlReserved (name mn)
          mDeclName = if alreadyDefMethod
            then mName <> "_" <> ocamlIdentifier cn
            else mName
      -- export (NamedSubsection MethodSection $ lowerName mn) (lowerName mn')
      -- returnsGObject <- maybe (return False) isGObject (returnType c)

      -- commentLine $ "method " <> name' <> "::" <> mName
      -- commentLine $ "method type : " <> tshow t

      -- let c' = if Constructor == t
      --       then fixConstructorReturnType returnsGObject cn c
      --       else c
      let c' = if OrdinaryMethod == t then fixMethodArgs c else c

      genCCallableWrapper mn sym c'

      typeReps     <- callableOCamlTypes c'
      mbMethodArgs <- typeRepsToMethodArgs typeReps

      case mbMethodArgs of
        Nothing    -> return ()
        Just mArgs -> do
          let tVars     = extractClassVars mArgs
              tVarsText = case tVars of
                []   -> ""
                vars -> T.intercalate " " (("'" <>) <$> vars) <> "."

          mSig  <- methodSignature tVarsText mArgs
          mBody <- methodBody tVars mName mArgs

          gline $ "  method " <> mDeclName <> mSig <> " = "
          gline $ "    " <> bodyPrefix mArgs <> mBody
          gline ""

 where
  methodSignature :: Text -> MethodArgs -> CodeGen Text
  methodSignature argVars (_, inArgs, outArg) = do
    inArgsShow <- mapM showMethodInArg inArgs
    outShow    <- showMethodOutArg outArg
    let argsShow = inArgsShow ++ [outShow]
    return $ " : " <> argVars <> T.intercalate " -> " argsShow

  bodyPrefix :: MethodArgs -> Text
  bodyPrefix (_, inArgs, _) = do
    let vars = extractVars inArgs
    case vars of
      [] -> ""
      _  -> "fun " <> T.intercalate " " vars <> " -> "

  methodBody :: [Text] -> Text -> MethodArgs -> CodeGen Text
  methodBody _ mName mArgs@(_, _, Class False n) = do
    ocamlClass <- getOCamlClass n
    return $ "new " <> ocamlClass <> " (" <> boundMethod mName mArgs <> ")"
  methodBody _ mName mArgs@(_, _, Class True n) = do
    ocamlClass <- getOCamlClass n
    return
      $  "Option.map (new "
      <> ocamlClass
      <> ") ("
      <> boundMethod mName mArgs
      <> ")"
  methodBody _ mName mArgs = return $ boundMethod mName mArgs

  getOCamlClass :: Name -> CodeGen Text
  getOCamlClass n = do
    ocamlClass <- nsOCamlClass n
    api        <- findAPIByName n
    return $ case api of
      APIObject    _ -> ocamlClass
      APIInterface _ -> ocamlClass <> "_skel"
      _ ->
        error
          "Error in (getOCamlClass): this name can only be an Object or an Interface"

  boundMethod :: Text -> MethodArgs -> Text
  boundMethod mName (headArg, inArgs, outArg) = do
    let obj = case headArg of
          ClassType _ _ _ -> " obj "
          _               -> " "
    name cn <> "." <> mName <> obj <> T.intercalate
      " "
      (mapInArg outArg <$> inArgs)
   where
    mapInArg _ (ClassType False tvar n) = tvar <> "#as_" <> ocamlIdentifier n
    mapInArg _ (ClassType True tvar n) =
      "(Option.map (fun z -> z#as_" <> ocamlIdentifier n <> ") " <> tvar <> ")"
    mapInArg _ (BasicIn tvar _          ) = tvar
    mapInArg _ (NonGtkClassType _ tvar _) = tvar
