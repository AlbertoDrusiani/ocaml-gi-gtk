{-# LANGUAGE PatternGuards, DeriveFunctor #-}

module Conversions
  ( convert
  , genConversion
  , unpackCArray
  , computeArrayLength
  , callableHasClosures
  , hToF
  , fToH
  , transientToH
  , haskellType
  , isoHaskellType
  , foreignType
  , argumentType
  , ExposeClosures(..)
  , elementType
  , elementMap
  , elementTypeAndMap
  , isManaged
  , typeIsNullable
  , typeIsPtr
  , typeIsCallback
  , maybeNullConvert
  , nullPtrForType
  , typeAllocInfo
  , TypeAllocInfo(..)
  , apply
  , mapC
  , literal
  , Constructor(..)
  , outParamOcamlType
  , ocamlDataConv
  , ocamlValueToC
  , cToOCamlValue
  , cType
  )
where

import           Control.Applicative            ( (<$>)
                                                , (<*>)
                                                , pure
                                                , Applicative
                                                )
import           Control.Monad                  ( when
                                                , unless
                                                )
import           Data.Maybe                     ( isJust
                                                , fromMaybe
                                                )
import           Data.Monoid                    ( (<>) )
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           GHC.Exts                       ( IsString(..) )

import           Foreign.C.Types                ( CInt
                                                , CUInt
                                                )
import           Foreign.Storable               ( sizeOf )

import           API

import           Type
import           Code
import           GObject
import           SymbolNaming
import           Util

import           Debug.Trace

-- | The free monad.
data Free f r = Free (f (Free f r)) | Pure r

instance Functor f => Functor (Free f) where
  fmap f = go   where
    go (Pure a ) = Pure (f a)
    go (Free fa) = Free (go <$> fa)

instance (Functor f) => Applicative (Free f) where
  pure = Pure
  Pure a  <*> Pure b  = Pure $ a b
  Pure a  <*> Free mb = Free $ fmap a <$> mb
  Free ma <*> b       = Free $ (<*> b) <$> ma

instance (Functor f) => Monad (Free f) where
  return = Pure
  (Free x) >>= f = Free (fmap (>>= f) x)
  (Pure r) >>= f = f r

-- | Lift some command to the Free monad.
liftF :: (Functor f) => f r -> Free f r
liftF command = Free (fmap Pure command)

-- String identifying a constructor in the generated code, which is
-- either (by default) a pure function (indicated by the P
-- constructor) or a function returning values on a monad (M
-- constructor). 'Id' denotes the identity function.
data Constructor = P Text | M Text | Id
                   deriving (Eq,Show)
instance IsString Constructor where
  fromString = P . T.pack

data FExpr next = Apply Constructor next
                | LambdaConvert Text next
                | MapC Map Constructor next
                | Literal Constructor next
                  deriving (Show, Functor)

type Converter = Free FExpr ()

-- Different available maps.
data Map = Map | MapFirst | MapSecond
         deriving (Show)

-- Naming for the maps.
mapName :: Map -> Text
mapName Map       = "map"
mapName MapFirst  = "mapFirst"
mapName MapSecond = "mapSecond"

-- Naming for the monadic versions of the maps that we use
monadicMapName :: Map -> Text
monadicMapName Map       = "mapM"
monadicMapName MapFirst  = "mapFirstA"
monadicMapName MapSecond = "mapSecondA"

apply :: Constructor -> Converter
apply f = liftF $ Apply f ()

mapC :: Constructor -> Converter
mapC f = liftF $ MapC Map f ()

mapFirst :: Constructor -> Converter
mapFirst f = liftF $ MapC MapFirst f ()

mapSecond :: Constructor -> Converter
mapSecond f = liftF $ MapC MapSecond f ()

literal :: Constructor -> Converter
literal f = liftF $ Literal f ()

lambdaConvert :: Text -> Converter
lambdaConvert c = liftF $ LambdaConvert c ()

genConversion :: Text -> Converter -> CodeGen Text
genConversion l (Pure ()) = return l
genConversion l (Free k ) = do
  let l' = prime l
  case k of
    Apply (P f) next -> do
      line $ "let " <> l' <> " = " <> f <> " " <> l
      genConversion l' next
    Apply (M f) next -> do
      line $ l' <> " <- " <> f <> " " <> l
      genConversion l' next
    Apply Id next     -> genConversion l next

    MapC m (P f) next -> do
      line $ "let " <> l' <> " = " <> mapName m <> " " <> f <> " " <> l
      genConversion l' next
    MapC m (M f) next -> do
      line $ l' <> " <- " <> monadicMapName m <> " " <> f <> " " <> l
      genConversion l' next
    MapC _ Id next          -> genConversion l next

    LambdaConvert conv next -> do
      line $ conv <> " " <> l <> " $ \\" <> l' <> " -> do"
      increaseIndent
      genConversion l' next

    Literal (P f) next -> do
      line $ "let " <> l <> " = " <> f
      genConversion l next
    Literal (M f) next -> do
      line $ l <> " <- " <> f
      genConversion l next
    Literal Id next -> genConversion l next

-- | Given an array, together with its type, return the code for reading
-- its length.
computeArrayLength :: Text -> Type -> ExcCodeGen Text
computeArrayLength array (TCArray _ _ _ t) = do
  reader <- findReader
  return $ "fromIntegral $ " <> reader <> " " <> array
 where
  findReader = case t of
    TBasicType TUInt8 -> return "B.length"
    TBasicType _      -> return "length"
    TInterface _      -> return "length"
    TCArray{}         -> return "length"
    _ ->
      notImplementedError $ "Don't know how to compute length of " <> tshow t
computeArrayLength _ t =
  notImplementedError
    $  "computeArrayLength called on non-CArray type "
    <> tshow t

convert :: Text -> BaseCodeGen e Converter -> BaseCodeGen e Text
convert l c = do
  c' <- c
  genConversion l c'

hObjectToF :: Type -> Transfer -> ExcCodeGen Constructor
hObjectToF t transfer = if transfer == TransferEverything
  then do
    isGO <- isGObject t
    if isGO
      then return $ M "B.ManagedPtr.disownObject"
      else badIntroError "Transferring a non-GObject object"
                        -- castPtr since we accept any instance of the class associated with
                        -- the GObject, not just the precise type of the GObject, while the
                        -- foreign function declaration requires a pointer of the precise
                        -- type.
  else return $ M "unsafeManagedPtrCastPtr"

hVariantToF :: Transfer -> CodeGen Constructor
hVariantToF transfer = if transfer == TransferEverything
  then return $ M "B.GVariant.disownGVariant"
  else return $ M "unsafeManagedPtrGetPtr"

hParamSpecToF :: Transfer -> CodeGen Constructor
hParamSpecToF transfer = if transfer == TransferEverything
  then return $ M "B.GParamSpec.disownGParamSpec"
  else return $ M "unsafeManagedPtrGetPtr"

hClosureToF :: Transfer -> Maybe Type -> CodeGen Constructor
-- Untyped closures
hClosureToF transfer Nothing = if transfer == TransferEverything
  then return $ M "B.GClosure.disownGClosure"
                               -- We cast the point here because the foreign type for untyped
                               -- closures is always represented as Ptr (GClosure ()), while the
                               -- corresponding Haskell type is the parametric "GClosure a".
  else return $ M "unsafeManagedPtrCastPtr"
-- Typed closures
hClosureToF transfer (Just _) = if transfer == TransferEverything
  then return $ M "B.GClosure.disownGClosure"
  else return $ M "unsafeManagedPtrGetPtr"

hBoxedToF :: Transfer -> CodeGen Constructor
hBoxedToF transfer = if transfer == TransferEverything
  then return $ M "B.ManagedPtr.disownBoxed"
  else return $ M "unsafeManagedPtrGetPtr"

hStructToF :: Struct -> Transfer -> ExcCodeGen Constructor
hStructToF s transfer = if transfer /= TransferEverything || structIsBoxed s
  then hBoxedToF transfer
  else do
    when (structSize s == 0)
      $ badIntroError "Transferring a non-boxed struct with unknown size!"
    return $ M "unsafeManagedPtrGetPtr"

hUnionToF :: Union -> Transfer -> ExcCodeGen Constructor
hUnionToF u transfer = if transfer /= TransferEverything || unionIsBoxed u
  then hBoxedToF transfer
  else do
    when (unionSize u == 0)
      $ badIntroError "Transferring a non-boxed union with unknown size!"
    return $ M "unsafeManagedPtrGetPtr"

-- Given the Haskell and Foreign types, returns the name of the
-- function marshalling between both.
hToF'
  :: Type
  -> Maybe API
  -> TypeRep
  -> TypeRep
  -> Transfer
  -> ExcCodeGen Constructor
hToF' t a hType fType transfer
  | (hType == fType)
  = return Id
  | TError <- t
  = hBoxedToF transfer
  | TVariant <- t
  = hVariantToF transfer
  | TParamSpec <- t
  = hParamSpecToF transfer
  | TGClosure c <- t
  = hClosureToF transfer c
  | Just (APIEnum _) <- a
  = return "(fromIntegral . fromEnum)"
  | Just (APIFlags _) <- a
  = return "gflagsToWord"
  | Just (APIObject _) <- a
  = hObjectToF t transfer
  | Just (APIInterface _) <- a
  = hObjectToF t transfer
  | Just (APIStruct s) <- a
  = hStructToF s transfer
  | Just (APIUnion u) <- a
  = hUnionToF u transfer
  |
    -- Converting callback types requires more context, we leave that
    -- as a special case to be implemented by the caller.
    Just (APICallback _) <- a
  = error "Cannot handle callback type here!! "
  | TByteArray <- t
  = return $ M "packGByteArray"
  | TCArray True _ _ (TBasicType TUTF8) <- t
  = return $ M "packZeroTerminatedUTF8CArray"
  | TCArray True _ _ (TBasicType TFileName) <- t
  = return $ M "packZeroTerminatedFileNameArray"
  | TCArray True _ _ (TBasicType TPtr) <- t
  = return $ M "packZeroTerminatedPtrArray"
  | TCArray True _ _ (TBasicType TUInt8) <- t
  = return $ M "packZeroTerminatedByteString"
  | TCArray True _ _ (TBasicType TBoolean) <- t
  = return $ M "(packMapZeroTerminatedStorableArray (fromIntegral . fromEnum))"
  | TCArray True _ _ (TBasicType TGType) <- t
  = return $ M "(packMapZeroTerminatedStorableArray gtypeToCGtype)"
  | TCArray True _ _ (TBasicType _) <- t
  = return $ M "packZeroTerminatedStorableArray"
  | TCArray False _ _ (TBasicType TUTF8) <- t
  = return $ M "packUTF8CArray"
  | TCArray False _ _ (TBasicType TFileName) <- t
  = return $ M "packFileNameArray"
  | TCArray False _ _ (TBasicType TPtr) <- t
  = return $ M "packPtrArray"
  | TCArray False _ _ (TBasicType TUInt8) <- t
  = return $ M "packByteString"
  | TCArray False _ _ (TBasicType TBoolean) <- t
  = return $ M "(packMapStorableArray (fromIntegral . fromEnum))"
  | TCArray False _ _ (TBasicType TGType) <- t
  = return $ M "(packMapStorableArray gtypeToCGType)"
  | TCArray False _ _ (TBasicType TFloat) <- t
  = return $ M "(packMapStorableArray realToFrac)"
  | TCArray False _ _ (TBasicType TDouble) <- t
  = return $ M "(packMapStorableArray realToFrac)"
  | TCArray False _ _ (TBasicType _) <- t
  = return $ M "packStorableArray"
  | TCArray{} <- t
  = notImplementedError $ "Don't know how to pack C array of type " <> tshow t
  | otherwise
  = case (typeShow hType, typeShow fType) of
    ("T.Text", "CString") -> return $ M "textToCString"
    ("[Char]", "CString") -> return $ M "stringToCString"
    ("Char"  , "CInt"   ) -> return "(fromIntegral . ord)"
    ("Bool"  , "CInt"   ) -> return "(fromIntegral . fromEnum)"
    ("Float" , "CFloat" ) -> return "realToFrac"
    ("Double", "CDouble") -> return "realToFrac"
    ("GType" , "CGType" ) -> return "gtypeToCGType"
    _ ->
      notImplementedError
        $  "Don't know how to convert "
        <> typeShow hType
        <> " into "
        <> typeShow fType
        <> ".\n"
        <> "Internal type: "
        <> tshow t

getForeignConstructor :: Type -> Transfer -> ExcCodeGen Constructor
getForeignConstructor t transfer = do
  a     <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  hToF' t a hType fType transfer

hToF_PackedType :: Type -> Text -> Transfer -> ExcCodeGen Converter
hToF_PackedType t packer transfer = do
  innerConstructor <- getForeignConstructor t transfer
  return $ do
    mapC innerConstructor
    apply (M packer)

-- | Try to find the `hash` and `equal` functions appropriate for the
-- given type, when used as a key in a GHashTable.
hashTableKeyMappings :: Type -> ExcCodeGen (Text, Text)
hashTableKeyMappings (TBasicType TPtr ) = return ("gDirectHash", "gDirectEqual")
hashTableKeyMappings (TBasicType TUTF8) = return ("gStrHash", "gStrEqual")
hashTableKeyMappings t =
  notImplementedError $ "GHashTable key of type " <> tshow t <> " unsupported."

-- | `GHashTable` tries to fit every type into a pointer, the
-- following function tries to find the appropriate
-- (destroy,packer,unpacker) for the given type.
hashTablePtrPackers :: Type -> ExcCodeGen (Text, Text, Text)
hashTablePtrPackers (TBasicType TPtr) =
  return ("Nothing", "ptrPackPtr", "ptrUnpackPtr")
hashTablePtrPackers (TBasicType TUTF8) =
  return ("(Just ptr_to_g_free)", "cstringPackPtr", "cstringUnpackPtr")
hashTablePtrPackers t =
  notImplementedError
    $  "GHashTable element of type "
    <> tshow t
    <> " unsupported."

hToF_PackGHashTable :: Type -> Type -> ExcCodeGen Converter
hToF_PackGHashTable keys elems = do
  -- We will be adding elements to the Hash list with appropriate
  -- destructors, so we always want a fresh copy.
  keysConstructor            <- getForeignConstructor keys TransferEverything
  elemsConstructor           <- getForeignConstructor elems TransferEverything
  (keyHash, keyEqual)        <- hashTableKeyMappings keys
  (keyDestroy , keyPack , _) <- hashTablePtrPackers keys
  (elemDestroy, elemPack, _) <- hashTablePtrPackers elems
  return $ do
    apply (P "Map.toList")
    mapFirst keysConstructor
    mapSecond elemsConstructor
    mapFirst (P keyPack)
    mapSecond (P elemPack)
    apply
      (M
        (T.intercalate
          " "
          ["packGHashTable", keyHash, keyEqual, keyDestroy, elemDestroy]
        )
      )

hToF :: Type -> Transfer -> ExcCodeGen Converter
hToF (TGList t) transfer = do
  isPtr <- typeIsPtr t
  when (not isPtr) $ badIntroError
    ("'" <> tshow t <> "' is not a pointer type, cannot pack into a GList.")
  hToF_PackedType t "packGList" transfer
hToF (TGSList t) transfer = do
  isPtr <- typeIsPtr t
  when (not isPtr) $ badIntroError
    ("'" <> tshow t <> "' is not a pointer type, cannot pack into a GSList.")
  hToF_PackedType t "packGSList" transfer
hToF (TGArray t) transfer = hToF_PackedType t "packGArray" transfer
hToF (TPtrArray t) transfer = hToF_PackedType t "packGPtrArray" transfer
hToF (TGHash ta tb) _ = hToF_PackGHashTable ta tb
hToF (TCArray zt _ _ t@(TCArray{})) transfer = do
  let packer = if zt then "packZeroTerminated" else "pack"
  hToF_PackedType t (packer <> "PtrArray") transfer

hToF (TCArray zt _ _ t@(TInterface _)) transfer = do
  isScalar <- typeIsEnumOrFlag t
  let packer = if zt then "packZeroTerminated" else "pack"
  if isScalar
    then hToF_PackedType t (packer <> "StorableArray") transfer
    else do
      api <- findAPI t
      let size = case api of
            Just (APIStruct s) -> structSize s
            Just (APIUnion  u) -> unionSize u
            _                  -> 0
      if size == 0 || zt
        then hToF_PackedType t (packer <> "PtrArray") transfer
        else hToF_PackedType t (packer <> "BlockArray " <> tshow size) transfer

hToF t transfer = do
  a           <- findAPI t
  hType       <- haskellType t
  fType       <- foreignType t
  constructor <- hToF' t a hType fType transfer
  return $ apply constructor

boxedForeignPtr :: Text -> Transfer -> CodeGen Constructor
boxedForeignPtr constructor transfer = return $ case transfer of
  TransferEverything -> M $ parenthesize $ "wrapBoxed " <> constructor
  _                  -> M $ parenthesize $ "newBoxed " <> constructor

suForeignPtr :: Bool -> TypeRep -> Transfer -> CodeGen Constructor
suForeignPtr isBoxed hType transfer = do
  let constructor = typeConName hType
  if isBoxed
    then boxedForeignPtr constructor transfer
    else return $ M $ parenthesize $ case transfer of
      TransferEverything -> "wrapPtr " <> constructor
      _                  -> "newPtr " <> constructor

structForeignPtr :: Struct -> TypeRep -> Transfer -> CodeGen Constructor
structForeignPtr s = suForeignPtr (structIsBoxed s)

unionForeignPtr :: Union -> TypeRep -> Transfer -> CodeGen Constructor
unionForeignPtr u = suForeignPtr (unionIsBoxed u)

fObjectToH :: Type -> TypeRep -> Transfer -> ExcCodeGen Constructor
fObjectToH t hType transfer = do
  let constructor = typeConName hType
  isGO <- isGObject t
  return $ M $ parenthesize $ case transfer of
    TransferEverything ->
      if isGO then "wrapObject " <> constructor else "wrapPtr " <> constructor
    _ -> if isGO then "newObject " <> constructor else "newPtr " <> constructor

fCallbackToH :: TypeRep -> Transfer -> ExcCodeGen Constructor
fCallbackToH hType TransferNothing = do
  let constructor = typeConName hType
  return (P (callbackDynamicWrapper constructor))
fCallbackToH _ transfer = notImplementedError
  ("ForeignCallback with unsupported transfer type `" <> tshow transfer <> "'")

fVariantToH :: Transfer -> CodeGen Constructor
fVariantToH transfer = return $ M $ case transfer of
  TransferEverything -> "B.GVariant.wrapGVariantPtr"
  _                  -> "B.GVariant.newGVariantFromPtr"

fParamSpecToH :: Transfer -> CodeGen Constructor
fParamSpecToH transfer = return $ M $ case transfer of
  TransferEverything -> "B.GParamSpec.wrapGParamSpecPtr"
  _                  -> "B.GParamSpec.newGParamSpecFromPtr"

fClosureToH :: Transfer -> Maybe Type -> CodeGen Constructor
-- Untyped closures
fClosureToH transfer Nothing = return $ M $ case transfer of
  TransferEverything ->
    parenthesize $ "B.GClosure.wrapGClosurePtr . FP.castPtr"
  _ -> parenthesize $ "B.GClosure.newGClosureFromPtr . FP.castPtr"
-- Typed closures
fClosureToH transfer (Just _) = return $ M $ case transfer of
  TransferEverything -> "B.GClosure.wrapGClosurePtr"
  _                  -> "B.GClosure.newGClosureFromPtr"

fToH'
  :: Type
  -> Maybe API
  -> TypeRep
  -> TypeRep
  -> Transfer
  -> ExcCodeGen Constructor
fToH' t a hType fType transfer
  | (hType == fType)
  = return Id
  | Just (APIEnum _) <- a
  = return "(toEnum . fromIntegral)"
  | Just (APIFlags _) <- a
  = return "wordToGFlags"
  | TError <- t
  = boxedForeignPtr "GError" transfer
  | TVariant <- t
  = fVariantToH transfer
  | TParamSpec <- t
  = fParamSpecToH transfer
  | TGClosure c <- t
  = fClosureToH transfer c
  | Just (APIStruct s) <- a
  = structForeignPtr s hType transfer
  | Just (APIUnion u) <- a
  = unionForeignPtr u hType transfer
  | Just (APIObject _) <- a
  = fObjectToH t hType transfer
  | Just (APIInterface _) <- a
  = fObjectToH t hType transfer
  | Just (APICallback _) <- a
  = fCallbackToH hType transfer
  | TCArray True _ _ (TBasicType TUTF8) <- t
  = return $ M "unpackZeroTerminatedUTF8CArray"
  | TCArray True _ _ (TBasicType TFileName) <- t
  = return $ M "unpackZeroTerminatedFileNameArray"
  | TCArray True _ _ (TBasicType TUInt8) <- t
  = return $ M "unpackZeroTerminatedByteString"
  | TCArray True _ _ (TBasicType TPtr) <- t
  = return $ M "unpackZeroTerminatedPtrArray"
  | TCArray True _ _ (TBasicType TBoolean) <- t
  = return $ M "(unpackMapZeroTerminatedStorableArray (/= 0))"
  | TCArray True _ _ (TBasicType TGType) <- t
  = return $ M "(unpackMapZeroTerminatedStorableArray GType)"
  | TCArray True _ _ (TBasicType TFloat) <- t
  = return $ M "(unpackMapZeroTerminatedStorableArray realToFrac)"
  | TCArray True _ _ (TBasicType TDouble) <- t
  = return $ M "(unpackMapZeroTerminatedStorableArray realToFrac)"
  | TCArray True _ _ (TBasicType _) <- t
  = return $ M "unpackZeroTerminatedStorableArray"
  | TCArray{} <- t
  = notImplementedError $ "Don't know how to unpack C array of type " <> tshow t
  | TByteArray <- t
  = return $ M "unpackGByteArray"
  | TGHash _ _ <- t
  = notImplementedError "Foreign Hashes not supported yet"
  | otherwise
  = case (typeShow fType, typeShow hType) of
    ("CString", "T.Text") -> return $ M "cstringToText"
    ("CString", "[Char]") -> return $ M "cstringToString"
    ("CInt"   , "Char"  ) -> return "(chr . fromIntegral)"
    ("CInt"   , "Bool"  ) -> return "(/= 0)"
    ("CFloat" , "Float" ) -> return "realToFrac"
    ("CDouble", "Double") -> return "realToFrac"
    ("CGType" , "GType" ) -> return "GType"
    _ ->
      notImplementedError
        $  "Don't know how to convert "
        <> typeShow fType
        <> " into "
        <> typeShow hType
        <> ".\n"
        <> "Internal type: "
        <> tshow t

getHaskellConstructor :: Type -> Transfer -> ExcCodeGen Constructor
getHaskellConstructor t transfer = do
  a     <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  fToH' t a hType fType transfer

fToH_PackedType :: Type -> Text -> Transfer -> ExcCodeGen Converter
fToH_PackedType t unpacker transfer = do
  innerConstructor <- getHaskellConstructor t transfer
  return $ do
    apply (M unpacker)
    mapC innerConstructor

fToH_UnpackGHashTable :: Type -> Type -> Transfer -> ExcCodeGen Converter
fToH_UnpackGHashTable keys elems transfer = do
  keysConstructor     <- getHaskellConstructor keys transfer
  (_, _, keysUnpack)  <- hashTablePtrPackers keys
  elemsConstructor    <- getHaskellConstructor elems transfer
  (_, _, elemsUnpack) <- hashTablePtrPackers elems
  return $ do
    apply (M "unpackGHashTable")
    mapFirst (P keysUnpack)
    mapFirst keysConstructor
    mapSecond (P elemsUnpack)
    mapSecond elemsConstructor
    apply (P "Map.fromList")

fToH :: Type -> Transfer -> ExcCodeGen Converter
fToH (TGList t) transfer = do
  isPtr <- typeIsPtr t
  when (not isPtr) $ badIntroError
    ("`" <> tshow t <> "' is not a pointer type, cannot unpack from a GList.")
  fToH_PackedType t "unpackGList" transfer
fToH (TGSList t) transfer = do
  isPtr <- typeIsPtr t
  when (not isPtr) $ badIntroError
    ("`" <> tshow t <> "' is not a pointer type, cannot unpack from a GSList.")
  fToH_PackedType t "unpackGSList" transfer
fToH (TGArray t) transfer = fToH_PackedType t "unpackGArray" transfer
fToH (TPtrArray t) transfer = fToH_PackedType t "unpackGPtrArray" transfer
fToH (TGHash a b) transfer = fToH_UnpackGHashTable a b transfer
-- We cannot unpack arrays without any kind of length info.
fToH t@(TCArray False (-1) (-1) _) _ = badIntroError
  ("`" <> tshow t <> "' is an array type, but contains no length information.")
fToH (TCArray True _ _ t@(TCArray{})) transfer =
  fToH_PackedType t "unpackZeroTerminatedPtrArray" transfer
fToH (TCArray True _ _ t@(TInterface _)) transfer = do
  isScalar <- typeIsEnumOrFlag t
  if isScalar
    then fToH_PackedType t "unpackZeroTerminatedStorableArray" transfer
    else fToH_PackedType t "unpackZeroTerminatedPtrArray" transfer

fToH t transfer = do
  a           <- findAPI t
  hType       <- haskellType t
  fType       <- foreignType t
  constructor <- fToH' t a hType fType transfer
  return $ apply constructor

-- | Somewhat like `fToH`, but with slightly different borrowing
-- semantics: in the case of `TransferNothing` we wrap incoming
-- pointers to boxed structs into transient `ManagedPtr`s (every other
-- case behaves as `fToH`). These are `ManagedPtr`s for which we do
-- not make a copy, and which will be disowned when the function
-- exists, instead of making a copy that the GC will collect
-- eventually.
--
-- This is necessary in order to get the semantics of callbacks and
-- signals right: in some cases making a copy of the object does not
-- simply increase the refcount, but rather makes a full copy. In this
-- cases modification of the original object is not possible, but this
-- is sometimes useful, see for example
--
-- https://github.com/haskell-gi/haskell-gi/issues/97
--
-- Another situation where making a copy of incoming arguments is
-- problematic is when the underlying library is not thread-safe. When
-- running under the threaded GHC runtime it can happen that the GC
-- runs on a different OS thread than the thread where the object was
-- created, and this leads to rather mysterious bugs, see for example
--
-- https://github.com/haskell-gi/haskell-gi/issues/96
--
-- This case is particularly nasty, since it affects `onWidgetDraw`,
-- which is very common.
transientToH :: Type -> Transfer -> ExcCodeGen Converter
transientToH t@(TInterface _) TransferNothing = do
  a <- findAPI t
  case a of
    Just (APIStruct s) ->
      if structIsBoxed s then wrapTransient t else fToH t TransferNothing
    Just (APIUnion u) ->
      if unionIsBoxed u then wrapTransient t else fToH t TransferNothing
    _ -> fToH t TransferNothing
transientToH t transfer = fToH t transfer

-- | Wrap the given transient.
wrapTransient :: Type -> CodeGen Converter
wrapTransient t = do
  hCon <- typeConName <$> haskellType t
  return $ lambdaConvert $ "B.ManagedPtr.withTransient " <> hCon

unpackCArray :: Text -> Type -> Transfer -> ExcCodeGen Converter
unpackCArray length (TCArray False _ _ t) transfer = case t of
  TBasicType TUTF8 ->
    return $ apply $ M $ parenthesize $ "unpackUTF8CArrayWithLength " <> length
  TBasicType TFileName ->
    return
      $  apply
      $  M
      $  parenthesize
      $  "unpackFileNameArrayWithLength "
      <> length
  TBasicType TUInt8 ->
    return $ apply $ M $ parenthesize $ "unpackByteStringWithLength " <> length
  TBasicType TPtr ->
    return $ apply $ M $ parenthesize $ "unpackPtrArrayWithLength " <> length
  TBasicType TBoolean ->
    return
      $  apply
      $  M
      $  parenthesize
      $  "unpackMapStorableArrayWithLength (/= 0) "
      <> length
  TBasicType TGType ->
    return
      $  apply
      $  M
      $  parenthesize
      $  "unpackMapStorableArrayWithLength GType "
      <> length
  TBasicType TFloat ->
    return
      $  apply
      $  M
      $  parenthesize
      $  "unpackMapStorableArrayWithLength realToFrac "
      <> length
  TBasicType TDouble ->
    return
      $  apply
      $  M
      $  parenthesize
      $  "unpackMapStorableArrayWithLength realToFrac "
      <> length
  TBasicType _ ->
    return
      $  apply
      $  M
      $  parenthesize
      $  "unpackStorableArrayWithLength "
      <> length
  TInterface _ -> do
    a                <- findAPI t
    isScalar         <- typeIsEnumOrFlag t
    hType            <- haskellType t
    fType            <- foreignType t
    innerConstructor <- fToH' t a hType fType transfer
    let (boxed, size) = case a of
          Just (APIStruct s) -> (structIsBoxed s, structSize s)
          Just (APIUnion  u) -> (unionIsBoxed u, unionSize u)
          _                  -> (False, 0)
    let unpacker | isScalar    = "unpackStorableArrayWithLength"
                 | (size == 0) = "unpackPtrArrayWithLength"
                 | boxed       = "unpackBoxedArrayWithLength " <> tshow size
                 | otherwise   = "unpackBlockArrayWithLength " <> tshow size
    return $ do
      apply $ M $ parenthesize $ unpacker <> " " <> length
      mapC innerConstructor
  _ ->
    notImplementedError
      $  "unpackCArray : Don't know how to unpack C Array of type "
      <> tshow t

unpackCArray _ _ _ =
  notImplementedError "unpackCArray : unexpected array type."

-- | Whether to expose closures and the associated destroy notify
-- handlers in the Haskell wrapper.
data ExposeClosures = WithClosures
                    | WithoutClosures
  deriving (Eq)

-- | Given a type find the typeclasses the type belongs to, and return
-- the representation of the type in the function signature and the
-- list of typeclass constraints for the type.
argumentType :: Type -> ExposeClosures -> CodeGen (Text, [Text])
argumentType (TGList a) expose = do
  (name, constraints) <- argumentType a expose
  return ("[" <> name <> "]", constraints)
argumentType (TGSList a) expose = do
  (name, constraints) <- argumentType a expose
  return ("[" <> name <> "]", constraints)
argumentType t expose = do
  api <- findAPI t
  s   <- typeShow <$> haskellType t
  case api of
    -- Instead of restricting to the actual class,
    -- we allow for any object descending from it.
    Just (APIInterface _) -> do
      cls <- typeConstraint t
      l   <- getFreshTypeVariable
      return (l, [cls <> " " <> l])
    Just (APIObject _) -> do
      isGO <- isGObject t
      if isGO
        then do
          cls <- typeConstraint t
          l   <- getFreshTypeVariable
          return (l, [cls <> " " <> l])
        else return (s, [])
    Just (APICallback cb) ->
      -- See [Note: Callables that throw]
                             if callableThrows (cbCallable cb)
      then do
        ft <- typeShow <$> foreignType t
        return (ft, [])
      else case expose of
        WithClosures -> do
          s_withClosures <- typeShow <$> isoHaskellType t
          return (s_withClosures, [])
        WithoutClosures -> return (s, [])
    _ -> return (s, [])

haskellBasicType :: BasicType -> TypeRep
haskellBasicType TPtr     = ptr $ con0 "()"
haskellBasicType TBoolean = con0 "Bool"
-- For all the platforms that we support (and those supported by glib)
-- we have gint == gint32. Encoding this assumption in the types saves
-- conversions.
haskellBasicType TInt     = case sizeOf (0 :: CInt) of
  4 -> con0 "Int32"
  n -> error ("Unsupported `gint' length: " ++ show n)
haskellBasicType TUInt = case sizeOf (0 :: CUInt) of
  4 -> con0 "Word32"
  n -> error ("Unsupported `guint' length: " ++ show n)
haskellBasicType TLong     = con0 "CLong"
haskellBasicType TULong    = con0 "CULong"
haskellBasicType TInt8     = con0 "Int8"
haskellBasicType TUInt8    = con0 "Word8"
haskellBasicType TInt16    = con0 "Int16"
haskellBasicType TUInt16   = con0 "Word16"
haskellBasicType TInt32    = con0 "Int32"
haskellBasicType TUInt32   = con0 "Word32"
haskellBasicType TInt64    = con0 "Int64"
haskellBasicType TUInt64   = con0 "Word64"
haskellBasicType TGType    = con0 "GType"
haskellBasicType TUTF8     = con0 "T.Text"
haskellBasicType TFloat    = con0 "Float"
haskellBasicType TDouble   = con0 "Double"
haskellBasicType TUniChar  = con0 "Char"
haskellBasicType TFileName = con0 "[Char]"
haskellBasicType TIntPtr   = con0 "CIntPtr"
haskellBasicType TUIntPtr  = con0 "CUIntPtr"

ocamlBasicType :: BasicType -> TypeRep
ocamlBasicType TPtr     = ptr $ con0 "()"
ocamlBasicType TBoolean = con0 "bool"
-- For all the platforms that we support (and those supported by glib)
-- we have gint == gint32. Encoding this assumption in the types saves
-- conversions.
ocamlBasicType TInt     = case sizeOf (0 :: CInt) of
  4 -> con0 "int"
  n -> error ("Unsupported `gint' length: " ++ show n)
ocamlBasicType TUInt = case sizeOf (0 :: CUInt) of
  4 -> con0 "int"
  n -> error ("Unsupported `guint' length: " ++ show n)
ocamlBasicType TLong     = con0 "int"
ocamlBasicType TULong    = con0 "int"
ocamlBasicType TInt8     = con0 "int"
ocamlBasicType TUInt8    = con0 "int"
ocamlBasicType TInt16    = con0 "int"
ocamlBasicType TUInt16   = con0 "int"
ocamlBasicType TInt32    = con0 "int"
ocamlBasicType TUInt32   = con0 "int"
ocamlBasicType TInt64    = con0 "int"
ocamlBasicType TUInt64   = con0 "int"
ocamlBasicType TGType    = con0 "GType"
ocamlBasicType TUTF8     = con0 "string"
ocamlBasicType TFloat    = con0 "float"
ocamlBasicType TDouble   = con0 "float"
ocamlBasicType TUniChar  = con0 "char"
ocamlBasicType TFileName = con0 "string"
ocamlBasicType TIntPtr   = undefined
ocamlBasicType TUIntPtr  = undefined

-- | This translates GI types to the types used for generated Haskell code.
-- haskellType :: Type -> CodeGen TypeRep
-- haskellType (TBasicType bt) = return $ haskellBasicType bt
-- -- There is no great choice in this case, so we simply pass the
-- -- pointer along. This is useful for GdkPixbufNotify, for example.
-- haskellType t@(TCArray False (-1) (-1) (TBasicType TUInt8)) =
--   foreignType t
-- haskellType (TCArray _ _ _ (TBasicType TUInt8)) =
--   return $ "ByteString" `con` []
-- haskellType (TCArray _ _ _ a) = do
--   inner <- haskellType a
--   return $ "[]" `con` [inner]
-- haskellType (TGArray a) = do
--   inner <- haskellType a
--   return $ "[]" `con` [inner]
-- haskellType (TPtrArray a) = do
--   inner <- haskellType a
--   return $ "[]" `con` [inner]
-- haskellType (TByteArray) = return $ "ByteString" `con` []
-- haskellType (TGList a) = do
--   inner <- haskellType a
--   return $ "[]" `con` [inner]
-- haskellType (TGSList a) = do
--   inner <- haskellType a
--   return $ "[]" `con` [inner]
-- haskellType (TGHash a b) = do
--   innerA <- haskellType a
--   innerB <- haskellType b
--   return $ "Map.Map" `con` [innerA, innerB]
-- haskellType TError = return $ "GError" `con` []
-- haskellType TVariant = return $ "GVariant" `con` []
-- haskellType TParamSpec = return $ "GParamSpec" `con` []
-- haskellType (TGClosure (Just inner@(TInterface n))) = do
--   innerAPI <- getAPI inner
--   case innerAPI of
--     APICallback _ -> do
--       tname <- qualifiedSymbol (callbackCType $ name n) n
--       return $ "GClosure" `con` [con0 tname]
--     -- The given inner type does not make sense, so we treat it as an
--     -- untyped closure.
--     _ -> haskellType (TGClosure Nothing)
-- haskellType (TGClosure _) = do
--   tyvar <- getFreshTypeVariable
--   return $ "GClosure" `con` [con0 tyvar]
-- haskellType (TInterface (Name "GObject" "Value")) = return $ "GValue" `con` []
-- haskellType t@(TInterface n) = do
--   api <- getAPI t
--   tname <- qualifiedAPI n
--   return $ case api of
--              (APIFlags _) -> "[]" `con` [tname `con` []]
--              _ -> tname `con` []

enumResolver :: Name -> CodeGen Text
enumResolver n = do
  currNS <- currentNS
  return $ if namespace n == currNS
    then currNS <> "Enums"
    else "GI" <> namespace n <> "." <> namespace n <> "Enums"

-- | This translates GI types to the types used for generated OCaml code.
haskellType :: Type -> CodeGen TypeRep
haskellType (TBasicType bt) = return $ ocamlBasicType bt
-- There is no great choice in this case, so we simply pass the
-- pointer along. This is useful for GdkPixbufNotify, for example.
haskellType t@(TCArray False (-1) (-1) (TBasicType TUInt8)) = foreignType t
haskellType (TCArray _ _ _ (TBasicType TUInt8)) =
  return $ "ByteString" `con` []
haskellType (TCArray _ _ _ a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGArray a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TPtrArray a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TByteArray) = return $ "ByteString" `con` []
haskellType (TGList a  ) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGSList a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGHash a b) = do
  innerA <- haskellType a
  innerB <- haskellType b
  return $ "Map.Map" `con` [innerA, innerB]
haskellType TError = return $ "GError" `con` []
haskellType TVariant = return $ "GVariant" `con` []
haskellType TParamSpec = return $ "GParamSpec" `con` []
haskellType (TGClosure (Just inner@(TInterface n))) = do
  innerAPI <- getAPI inner
  case innerAPI of
    APICallback _ -> do
      tname <- qualifiedSymbol (callbackCType $ name n) n
      return $ "GClosure" `con` [con0 tname]
    -- The given inner type does not make sense, so we treat it as an
    -- untyped closure.
    _ -> haskellType (TGClosure Nothing)
haskellType (TGClosure _) = do
  tyvar <- getFreshTypeVariable
  return $ "GClosure" `con` [con0 tyvar]
haskellType (  TInterface (Name "GObject" "Value")) = return $ "GValue" `con` []
haskellType t@(TInterface n                       ) = do
  let ocamlName = camelCaseToSnakeCase $ name n
      tname     = lowerName n
  api <- getAPI t
  case api of
    APIFlags     _f -> return $ "[]" `con` [tname `con` []]
    APIEnum      _e -> do
      enumRes <- enumResolver n
      return $ (enumRes <> "." <> ocamlName) `con` []
    APIObject    _o -> handleObj ocamlName
    APIInterface _i -> handleObj ocamlName
    APIStruct    _s -> do
      currModule <- currentModule
      currNS     <- currentNS
      let currModuleName = last $ T.splitOn "." currModule

      return $ case (currModuleName == name n, currNS == namespace n) of
        (True , _    ) -> "t" `con` []
        (False, True ) -> (name n <> ".t") `con` []
        (False, False) -> ("GI" <> namespace n <> "." <> name n <> ".t") `con` []
    APIConst    _c -> return $ "const" `con` []
    APIFunction _f -> return $ "function" `con` []
    APICallback _c -> return $ "callback" `con` []
    APIUnion    _u -> return $ "union" `con` []
  where
    handleObj ocamlName = do
      freshVar <- getFreshTypeVariable
      let typeVarCon = typevar freshVar
      return $ obj $ typeVarCon $ polyMore $ ocamlName `con` []

-- | Whether the callable has closure arguments (i.e. "user_data"
-- style arguments).
callableHasClosures :: Callable -> Bool
callableHasClosures = any (/= -1) . map argClosure . args

-- | Check whether the given type corresponds to a callback.
typeIsCallback :: Type -> CodeGen Bool
typeIsCallback t@(TInterface _) = do
  api <- findAPI t
  case api of
    Just (APICallback _) -> return True
    _                    -> return False
typeIsCallback _ = return False

-- | Basically like `haskellType`, but for types which admit a
-- "isomorphic" version of the Haskell type distinct from the usual
-- Haskell type.  Generally the Haskell type we expose is isomorphic
-- to the foreign type, but in some cases, such as callbacks with
-- closure arguments, this does not hold, as we omit the closure
-- arguments. This function returns a type which is actually
-- isomorphic. There is another case this function deals with: for
-- convenience untyped `TGClosure` types have a type variable on the
-- Haskell side when they are arguments to functions, but we do not
-- want this when they appear as arguments to callbacks/signals, or
-- return types of properties, as it would force the type synonym/type
-- family to depend on the type variable.
isoHaskellType :: Type -> CodeGen TypeRep
isoHaskellType (  TGClosure  Nothing) = return $ "GClosure" `con` [con0 "()"]
isoHaskellType t@(TInterface n      ) = do
  api <- findAPI t
  case api of
    Just (APICallback cb) -> do
      tname <- qualifiedAPI n
      if callableHasClosures (cbCallable cb)
        then return ((callbackHTypeWithClosures tname) `con` [])
        else return (tname `con` [])
    _ -> haskellType t
isoHaskellType t = haskellType t

-- | Foreign (C) type associated to one of the basic types.
foreignBasicType :: BasicType -> TypeRep
foreignBasicType TBoolean  = "CInt" `con` []
foreignBasicType TUTF8     = "CString" `con` []
foreignBasicType TFileName = "CString" `con` []
foreignBasicType TUniChar  = "CInt" `con` []
foreignBasicType TFloat    = "CFloat" `con` []
foreignBasicType TDouble   = "CDouble" `con` []
foreignBasicType TGType    = "CGType" `con` []
foreignBasicType t         = haskellBasicType t

-- This translates GI types to the types used in foreign function calls.
foreignType :: Type -> CodeGen TypeRep
foreignType (TBasicType t    ) = return $ foreignBasicType t
foreignType (TCArray zt _ _ t) = do
  api <- findAPI t
  let size = case api of
        Just (APIStruct s) -> structSize s
        Just (APIUnion  u) -> unionSize u
        _                  -> 0
  if size == 0 || zt then ptr <$> foreignType t else foreignType t
foreignType (TGArray a) = do
  inner <- foreignType a
  return $ ptr ("GArray" `con` [inner])
foreignType (TPtrArray a) = do
  inner <- foreignType a
  return $ ptr ("GPtrArray" `con` [inner])
foreignType (TByteArray) = return $ ptr ("GByteArray" `con` [])
foreignType (TGList a  ) = do
  inner <- foreignType a
  return $ ptr ("GList" `con` [inner])
foreignType (TGSList a) = do
  inner <- foreignType a
  return $ ptr ("GSList" `con` [inner])
foreignType (TGHash a b) = do
  innerA <- foreignType a
  innerB <- foreignType b
  return $ ptr ("GHashTable" `con` [innerA, innerB])
foreignType t@TError               = ptr <$> haskellType t
foreignType t@TVariant             = ptr <$> haskellType t
foreignType t@TParamSpec           = ptr <$> haskellType t
foreignType (  TGClosure Nothing ) = return $ ptr ("GClosure" `con` [con0 "()"])
foreignType t@(TGClosure (Just _)) = ptr <$> haskellType t
foreignType (TInterface (Name "GObject" "Value")) =
  return $ ptr $ "GValue" `con` []
foreignType t@(TInterface n) = do
  api <- getAPI t
  let enumIsSigned e = any (< 0) (map enumMemberValue (enumMembers e))
      ctypeForEnum e = if enumIsSigned e then "CInt" else "CUInt"
  case api of
    APIEnum     e         -> return $ (ctypeForEnum e) `con` []
    APIFlags    (Flags e) -> return $ (ctypeForEnum e) `con` []
    APICallback _         -> do
      tname <- qualifiedSymbol (callbackCType $ name n) n
      return (funptr $ tname `con` [])
    _ -> do
      tname <- qualifiedAPI n
      return (ptr $ tname `con` [])

-- | Whether the give type corresponds to an enum or flag.
typeIsEnumOrFlag :: Type -> CodeGen Bool
typeIsEnumOrFlag t = do
  a <- findAPI t
  case a of
    Nothing             -> return False
    (Just (APIEnum  _)) -> return True
    (Just (APIFlags _)) -> return True
    _                   -> return False

-- | Information on how to allocate a type.
data TypeAllocInfo = TypeAllocInfo {
      typeAllocInfoIsBoxed :: Bool
    , typeAllocInfoSize    :: Int -- ^ In bytes.
    }

-- | Information on how to allocate the given type, if known.
typeAllocInfo :: Type -> CodeGen (Maybe TypeAllocInfo)
typeAllocInfo t = do
  api <- findAPI t
  case api of
    Just (APIStruct s) -> case structSize s of
      0 -> return Nothing
      n ->
        let info = TypeAllocInfo { typeAllocInfoIsBoxed = structIsBoxed s
                                 , typeAllocInfoSize    = n
                                 }
        in  return (Just info)
    _ -> return Nothing

-- | Returns whether the given type corresponds to a `ManagedPtr`
-- instance (a thin wrapper over a `ForeignPtr`).
isManaged :: Type -> CodeGen Bool
isManaged TError           = return True
isManaged TVariant         = return True
isManaged TParamSpec       = return True
isManaged (  TGClosure  _) = return True
isManaged t@(TInterface _) = do
  a <- findAPI t
  case a of
    Just (APIObject    _) -> return True
    Just (APIInterface _) -> return True
    Just (APIStruct    _) -> return True
    Just (APIUnion     _) -> return True
    _                     -> return False
isManaged _ = return False

-- | Returns whether the given type is represented by a pointer on the
-- C side.
typeIsPtr :: Type -> CodeGen Bool
typeIsPtr t = isJust <$> typePtrType t

-- | Distinct types of foreign pointers.
data FFIPtrType = FFIPtr    -- ^ Ordinary `Ptr`.
                | FFIFunPtr -- ^ `FunPtr`.

-- | For those types represented by pointers on the C side, return the
-- type of pointer which represents them on the Haskell FFI.
typePtrType :: Type -> CodeGen (Maybe FFIPtrType)
typePtrType (TBasicType TPtr     ) = return (Just FFIPtr)
typePtrType (TBasicType TUTF8    ) = return (Just FFIPtr)
typePtrType (TBasicType TFileName) = return (Just FFIPtr)
typePtrType t                      = do
  ft <- foreignType t
  case typeConName ft of
    "Ptr"    -> return (Just FFIPtr)
    "FunPtr" -> return (Just FFIFunPtr)
    _        -> return Nothing

-- | If the passed in type is nullable, return the conversion function
-- between the FFI pointer type (may be a `Ptr` or a `FunPtr`) and the
-- corresponding `Maybe` type.
maybeNullConvert :: Type -> CodeGen (Maybe Text)
maybeNullConvert (TBasicType TPtr) = return Nothing
maybeNullConvert (TGList     _   ) = return Nothing
maybeNullConvert (TGSList    _   ) = return Nothing
maybeNullConvert t                 = do
  pt <- typePtrType t
  case pt of
    Just FFIPtr    -> return (Just "SP.convertIfNonNull")
    Just FFIFunPtr -> return (Just "SP.convertFunPtrIfNonNull")
    Nothing        -> return Nothing

-- | An appropriate NULL value for the given type, for types which are
-- represented by pointers on the C side.
nullPtrForType :: Type -> CodeGen (Maybe Text)
nullPtrForType t = do
  pt <- typePtrType t
  case pt of
    Just FFIPtr    -> return (Just "FP.nullPtr")
    Just FFIFunPtr -> return (Just "FP.nullFunPtr")
    Nothing        -> return Nothing

-- | Returns whether the given type should be represented by a
-- `Maybe` type on the Haskell side. This applies to all properties
-- which have a C representation in terms of pointers, except for
-- G(S)Lists, for which NULL is a valid G(S)List, and raw pointers,
-- which we just pass through to the Haskell side. Notice that
-- introspection annotations can override this.
typeIsNullable :: Type -> CodeGen Bool
typeIsNullable t = isJust <$> maybeNullConvert t

-- | If the given type maps to a list in Haskell, return the type of the
-- elements, and the function that maps over them.
elementTypeAndMap :: Type -> Text -> Maybe (Type, Text)
-- ByteString
elementTypeAndMap (TCArray _ _ _ (TBasicType TUInt8)) _ = Nothing
elementTypeAndMap (TCArray True _ _ t) _ = Just (t, "mapZeroTerminatedCArray")
elementTypeAndMap (TCArray False (-1) _ t) len =
  Just (t, parenthesize $ "mapCArrayWithLength " <> len)
elementTypeAndMap (TCArray False fixed _ t) _ =
  Just (t, parenthesize $ "mapCArrayWithLength " <> tshow fixed)
elementTypeAndMap (TGArray   t) _ = Just (t, "mapGArray")
elementTypeAndMap (TPtrArray t) _ = Just (t, "mapPtrArray")
elementTypeAndMap (TGList    t) _ = Just (t, "mapGList")
elementTypeAndMap (TGSList   t) _ = Just (t, "mapGSList")
-- GHashTable is treated separately, see Transfer.hs
elementTypeAndMap _             _ = Nothing

-- Return just the element type.
elementType :: Type -> Maybe Type
elementType t = fst <$> elementTypeAndMap t undefined

-- Return just the map.
elementMap :: Type -> Text -> Maybe Text
elementMap t len = snd <$> elementTypeAndMap t len

-- | This translates GI types to the types used for generated OCaml code.
outParamOcamlType :: Type -> CodeGen TypeRep
outParamOcamlType (TBasicType bt) = return $ ocamlBasicType bt
-- There is no great choice in this case, so we simply pass the
-- pointer along. This is useful for GdkPixbufNotify, for example.
outParamOcamlType t@(TCArray False (-1) (-1) (TBasicType TUInt8)) =
  foreignType t
outParamOcamlType (TCArray _ _ _ (TBasicType TUInt8)) =
  return $ "ByteString" `con` []
outParamOcamlType (TCArray _ _ _ a) = do
  inner <- outParamOcamlType a
  return $ "[]" `con` [inner]
outParamOcamlType (TGArray a) = do
  inner <- outParamOcamlType a
  return $ "[]" `con` [inner]
outParamOcamlType (TPtrArray a) = do
  inner <- outParamOcamlType a
  return $ "[]" `con` [inner]
outParamOcamlType (TByteArray) = return $ "ByteString" `con` []
outParamOcamlType (TGList a  ) = do
  inner <- outParamOcamlType a
  return $ "[]" `con` [inner]
outParamOcamlType (TGSList a) = do
  inner <- outParamOcamlType a
  return $ "[]" `con` [inner]
outParamOcamlType (TGHash a b) = do
  innerA <- outParamOcamlType a
  innerB <- outParamOcamlType b
  return $ "Map.Map" `con` [innerA, innerB]
outParamOcamlType TError = return $ "GError" `con` []
outParamOcamlType TVariant = return $ "GVariant" `con` []
outParamOcamlType TParamSpec = return $ "GParamSpec" `con` []
outParamOcamlType (TGClosure (Just inner@(TInterface n))) = do
  innerAPI <- getAPI inner
  case innerAPI of
    APICallback _ -> do
      tname <- qualifiedSymbol (callbackCType $ name n) n
      return $ "GClosure" `con` [con0 tname]
    -- The given inner type does not make sense, so we treat it as an
    -- untyped closure.
    _ -> outParamOcamlType (TGClosure Nothing)
outParamOcamlType (TGClosure _) = do
  tyvar <- getFreshTypeVariable
  return $ "GClosure" `con` [con0 tyvar]
outParamOcamlType (TInterface (Name "GObject" "Value")) =
  return $ "GValue" `con` []
outParamOcamlType t@(TInterface n) = do
  let ocamlName = camelCaseToSnakeCase $ name n
      tname     = lowerName n
  api <- getAPI t
  case api of
    APIFlags _    -> return $ "[]" `con` [tname `con` []]
    APIEnum _enum -> do
      enumRes <- enumResolver n
      return $ (enumRes <> "." <> ocamlName) `con` []
    APIInterface _ -> handleObj ocamlName
    APIObject _ -> handleObj ocamlName
    _ -> return $ con0 "error"
  where
    handleObj ocamlName = do
      freshVar <- getFreshTypeVariable
      let typeVarCon = typevar freshVar
      return $ obj $ typeVarCon $ polyLess $ ocamlName `con` [] 

cType :: Type -> ExcCodeGen Text
cType (TBasicType t) = case t of
  TBoolean  -> return "gboolean"
  TInt      -> return "gint"
  TUInt     -> return "guint"
  TLong     -> return "glong"
  TULong    -> return "gulong"
  TInt8     -> return "gint8"
  TUInt8    -> return "guint8"
  TInt16    -> return "gint16"
  TUInt16   -> return "guint16"
  TInt32    -> return "gint32"
  TUInt32   -> return "guint32"
  TInt64    -> return "gint64"
  TUInt64   -> return "guint64"
  TFloat    -> return "gfloat"
  TDouble   -> return "gdouble"
  TUniChar  -> return "gchar"
  TGType    -> notImplementedError "This cType (TGType) isn't implemented yet"
  TUTF8     -> return "gchar*"
  TFileName -> return "gchar*"
  TPtr      -> return "gpointer"
  TIntPtr   -> return "gintptr"
  TUIntPtr  -> return "guintptr"
cType (TError) =
  notImplementedError "This cType (TError) isn't implemented yet"
cType (TVariant) =
  notImplementedError "This cType (TVariant) isn't implemented yet"
cType (TParamSpec) =
  notImplementedError "This cType (TParamSpec) isn't implemented yet"
cType (TCArray _b _i1 _i2 _t) =
  notImplementedError "This cType (TCArray) isn't implemented yet"
cType (TGArray _t) =
  notImplementedError "This cType (TGArray) isn't implemented yet"
cType (TPtrArray _t) =
  notImplementedError "This cType (TPtrArray) isn't implemented yet"
cType (TByteArray) =
  notImplementedError "This cType (TByteArray) isn't implemented yet"
cType (TGList _t) =
  notImplementedError "This cType (TGList) isn't implemented yet"
cType (TGSList _t) =
  notImplementedError "This cType (TGSList) isn't implemented yet"
cType (TGHash _t1 _t2) =
  notImplementedError "This cType (TGHash) isn't implemented yet"
cType (TGClosure _m) =
  notImplementedError "This cType (TGClosure) isn't implemented yet"
cType (TInterface n) = return $ namespace n <> name n


-- Type to data_conv
ocamlDataConv
  :: Bool             -- ^ is nullable
  -> Type
  -> ExcCodeGen Text
ocamlDataConv _ (TBasicType t) = case t of
  TBoolean -> return "boolean"
  TInt     -> return "int"
  TUInt    -> return "uint"
  TLong    -> return "long"
  TULong   -> return "ulong"
  TInt8    -> notImplementedError "This ocamlDataConv (TInt8) isn't implemented"
  TUInt8 -> notImplementedError "This ocamlDataConv (TUInt8) isn't implemented"
  TInt16 -> notImplementedError "This ocamlDataConv (TInt16) isn't implemented"
  TUInt16 ->
    notImplementedError "This ocamlDataConv (TUInt16) isn't implemented"
  TInt32   -> return "int32"
  TUInt32  -> return "uint32"
  TInt64   -> return "int64"
  TUInt64  -> return "uint64"
  TFloat   -> return "float"
  TDouble  -> return "double"
  TUniChar -> return "char"
  TGType ->
    notImplementedError "This ocamlDataConv (TGType) isn't implemented yet"
  TUTF8     -> return "string"
  TFileName -> return "string"
  TPtr      -> do
    traceShowM "Warning: ocamlDataConv has defaulted a TPtr to int"
    return "int"
  TIntPtr ->
    notImplementedError "This ocamlDataConv (TIntPtr) isn't implemented yet"
  TUIntPtr ->
    notImplementedError "This ocamlDataConv (TUIntPtr) isn't implemented yet"
ocamlDataConv _ (TError) =
  notImplementedError "This ocamlDataConv (TError) isn't implemented yet"
ocamlDataConv _ (TVariant) =
  notImplementedError "This ocamlDataConv (TVariant) isn't implemented yet"
ocamlDataConv _ (TParamSpec) =
  notImplementedError "This ocamlDataConv (TParamSpec) isn't implemented yet"
ocamlDataConv _ (TCArray _b _i1 _i2 _t) =
  notImplementedError "This ocamlDataConv (TCArray) isn't implemented yet"
ocamlDataConv _ (TGArray _t) =
  notImplementedError "This ocamlDataConv (TGArray) isn't implemented yet"
ocamlDataConv _ (TPtrArray _t) =
  notImplementedError "This ocamlDataConv (TPtrArray) isn't implemented yet"
ocamlDataConv _ (TByteArray) =
  notImplementedError "This ocamlDataConv (TByteArray) isn't implemented yet"
ocamlDataConv _ (TGList _t) =
  notImplementedError "This ocamlDataConv (TGList) isn't implemented yet"
ocamlDataConv _ (TGSList _t) =
  notImplementedError "This ocamlDataConv (TGSList) isn't implemented yet"
ocamlDataConv _ (TGHash _t1 _t2) =
  notImplementedError "This ocamlDataConv (TGHash) isn't implemented yet"
ocamlDataConv _ (TGClosure _m) =
  notImplementedError "This ocamlDataConv (TGClosure) isn't implemented yet"
ocamlDataConv isNullable (TInterface n) = do
  api <- findAPIByName n
  case api of
    APIConst _c ->
      notImplementedError "This ocamlDataConv (APIConst) isn't implemented yet"
    APIFunction _f -> notImplementedError
      "This ocamlDataConv (APIFunction) isn't implemented yet"
    APICallback _c -> notImplementedError
      "This ocamlDataConv (APICallback) isn't implemented yet"
    APIEnum      _enum -> enumFlagConv n
    APIFlags     _f    -> enumFlagConv n
    APIInterface _i    -> notImplementedError
      "This ocamlDataConv (APIInterface) isn't implemented yet"
    APIObject _o -> do
      currMod <- currentModule
      currNs  <- currentNS
      if namespace n == currNs
        then do
          let currModuleName = last $ T.splitOn "." currMod
          return $ if name n == currModuleName
            then converter "t"
            else converter (name n <> ".t")
        else do
          let nspace = case namespace n of
                "Pixbuf" -> "GdkPixbuf"  -- TODO: this is kinda hardcoded until we can generate Pixbuf
                nspace   -> nspace
          return $ converter (nspace <> "." <> camelCaseToSnakeCase (name n))

     where
      converter' False conv = "(gobject : " <> conv <> " obj data_conv)"
      converter' True conv =
        "(gobject_option : " <> conv <> " obj option data_conv)"
      converter = converter' isNullable
    APIStruct s -> case structCType s of
      Just t -> if "GdkEvent" `T.isPrefixOf` t
        then do
          let eventType = last $ splitCamelCase t
          return $ "(unsafe_pointer : GdkEvent." <> eventType <> ".t data_conv)"
        else notImplementedError
          "This ocamlDataConv (APIStruct) isn't implemented yet"
      Nothing -> notImplementedError
        "This ocamlDataConv (APIStruct) isn't implemented yet"
    APIUnion _u ->
      notImplementedError "This ocamlDataConv (APIUnion) isn't implemented yet"
 where
  enumFlagConv n = do
    enumRes <- enumResolver n
    return $ enumRes <> "." <> camelCaseToSnakeCase (name n)
          -- return $ T.toTitle (namespace n) <> "Enums.Conv." <> ocamlName

-- Converter from value to C
ocamlValueToC :: Type -> ExcCodeGen Text
ocamlValueToC (TBasicType t) = case t of
  TBoolean -> return "Bool_val"
  TInt     -> return "Int_val"
  TUInt    -> return "Int_val"
  TLong    -> return "Long_val"
  TULong   -> return "Long_val"
  TInt8 ->
    notImplementedError "This ocamlValueToC (TInt8) isn't implemented yet"
  TUInt8 ->
    notImplementedError "This ocamlValueToC (TUInt8) isn't implemented yet"
  TInt16 ->
    notImplementedError "This ocamlValueToC (TInt16) isn't implemented yet"
  TUInt16 ->
    notImplementedError "This ocamlValueToC (TUInt16) isn't implemented yet"
  TInt32 ->
    notImplementedError "This ocamlValueToC (TInt32) isn't implemented yet"
  TUInt32 ->
    notImplementedError "This ocamlValueToC (TUInt32) isn't implemented yet"
  TInt64 ->
    notImplementedError "This ocamlValueToC (TInt64) isn't implemented yet"
  TUInt64 ->
    notImplementedError "This ocamlValueToC (TUInt64) isn't implemented yet"
  TFloat   -> return "Float_val"
  TDouble  -> return "Double_val"
  TUniChar -> return "Char_val"
  TGType ->
    notImplementedError "This ocamlValueToC (TGType) isn't implemented yet"
  TUTF8 -> return "String_val"
  TFileName -> return "String_val"
  TPtr -> notImplementedError "This ocamlValueToC (TPtr) isn't implemented yet"
  TIntPtr ->
    notImplementedError "This ocamlValueToC (TIntPtr) isn't implemented yet"
  TUIntPtr ->
    notImplementedError "This ocamlValueToC (TUIntPtr) isn't implemented yet"
ocamlValueToC TError =
  notImplementedError "This ocamlValueToC (TError) isn't implemented yet"
ocamlValueToC TVariant =
  notImplementedError "This ocamlValueToC (TVariant) isn't implemented yet"
ocamlValueToC TParamSpec =
  notImplementedError "This ocamlValueToC (TParamSpec) isn't implemented yet"
ocamlValueToC (TCArray _b _i1 _i2 _t) =
  notImplementedError "This ocamlValueToC (TCArray) isn't implemented yet"
ocamlValueToC (TGArray _t) =
  notImplementedError "This ocamlValueToC (TGArray) isn't implemented yet"
ocamlValueToC (TPtrArray _t) =
  notImplementedError "This ocamlValueToC (TPtrArray) isn't implemented yet"
ocamlValueToC TByteArray =
  notImplementedError "This ocamlValueToC (TByteArray) isn't implemented yet"
ocamlValueToC (TGList _t) =
  notImplementedError "This ocamlValueToC (TGList) isn't implemented yet"
ocamlValueToC (TGSList _t) =
  notImplementedError "This ocamlValueToC (TGSList) isn't implemented yet"
ocamlValueToC (TGHash _t1 _t2) =
  notImplementedError "This ocamlValueToC (TGHash) isn't implemented yet"
ocamlValueToC (TGClosure _m) =
  notImplementedError "This ocamlValueToC (TGClosure) isn't implemented yet"
ocamlValueToC (TInterface n) = do
  api <- findAPIByName n
  case api of
    APIConst _c ->
      notImplementedError "This ocamlValueToC (APIConst) isn't implemented yet"
    APIFunction _f -> notImplementedError
      "This ocamlValueToC (APIFunction) isn't implemented yet"
    APICallback _c -> notImplementedError
      "This ocamlValueToC (APICallback) isn't implemented yet"
    APIEnum _enum -> do
      addCDep $ namespace n <> "Enums"
      return $ T.toTitle (camelCaseToSnakeCase $ name n) <> "_val"
    APIFlags _f ->
      notImplementedError "This ocamlValueToC (APIFlags) isn't implemented yet"
    APIInterface i -> do
      let typ = fromMaybe (namespace n <> name n) (ifCType i)
      return $ typ <> "_val"
    APIObject    o  -> converter $ objTypeName o
    APIStruct    _s -> converter $ namespace n <> name n
    APIUnion _u ->
      notImplementedError "This ocamlValueToC (APIUnion) isn't implemented yet"
 where
  converter typename = do
    currNS <- currentNS
    unless (namespace n `elem` ["Gio", "GdkPixbuf"]) $ addCDep (name n)
    return $ typename <> "_val"
  
-- Converter from C to value
cToOCamlValue
  :: Bool               -- ^ is nullable
  -> Maybe Type
  -> ExcCodeGen Text
cToOCamlValue _     Nothing               = return "Unit"
cToOCamlValue False (Just (TBasicType t)) = case t of
  TBoolean -> return "Val_bool"
  TInt     -> return "Val_int"
  TUInt    -> return "Val_int"
  TLong    -> return "Val_long"
  TULong   -> return "Val_long"
  TInt8 ->
    notImplementedError "This cToOCamlValue (TInt8) isn't implemented yet"
  TUInt8 ->
    notImplementedError "This cToOCamlValue (TUInt8) isn't implemented yet"
  TInt16 ->
    notImplementedError "This cToOCamlValue (TInt16) isn't implemented yet"
  TUInt16 ->
    notImplementedError "This cToOCamlValue (TUInt16) isn't implemented yet"
  TInt32   -> return "caml_copy_int32"
  TUInt32  -> return "caml_copy_int32"
  TInt64   -> return "caml_copy_int64"
  TUInt64  -> return "caml_copy_int64"
  TFloat   -> return "caml_copy_double"
  TDouble  -> return "caml_copy_double"
  TUniChar -> return "Val_char"
  TGType ->
    notImplementedError "This cToOCamlValue (TGType) isn't implemented yet"
  TUTF8 -> return "Val_string"
  TFileName -> return "Val_string"
  TPtr -> notImplementedError "This cToOCamlValue (TPtr) isn't implemented yet"
  TIntPtr ->
    notImplementedError "This cToOCamlValue (TIntPtr) isn't implemented yet"
  TUIntPtr ->
    notImplementedError "This cToOCamlValue (TUIntPtr) isn't implemented yet"
cToOCamlValue False (Just (TError)) =
  notImplementedError "This cToOCamlValue (TError) isn't implemented yet"
cToOCamlValue False (Just (TVariant)) =
  notImplementedError "This cToOCamlValue (TVariant) isn't implemented yet"
cToOCamlValue False (Just (TParamSpec)) =
  notImplementedError "This cToOCamlValue (TParamSpec) isn't implemented yet"
cToOCamlValue False (Just (TCArray _b _i1 _i2 _t)) =
  notImplementedError "This cToOCamlValue (TCArray) isn't implemented yet"
cToOCamlValue False (Just (TGArray _t)) =
  notImplementedError "This cToOCamlValue (TGArray) isn't implemented yet"
cToOCamlValue False (Just (TPtrArray _t)) =
  notImplementedError "This cToOCamlValue (TPtrArray) isn't implemented yet"
cToOCamlValue False (Just (TByteArray)) =
  notImplementedError "This cToOCamlValue (TByteArray) isn't implemented yet"
cToOCamlValue False (Just (TGList _t)) =
  notImplementedError "This cToOCamlValue (TGList) isn't implemented yet"
cToOCamlValue False (Just (TGSList _t)) =
  notImplementedError "This cToOCamlValue (TGSList) isn't implemented yet"
cToOCamlValue False (Just (TGHash _t1 _t2)) =
  notImplementedError "This cToOCamlValue (TGHash) isn't implemented yet"
cToOCamlValue False (Just (TGClosure _m)) =
  notImplementedError "This cToOCamlValue (TGClosure) isn't implemented yet"
cToOCamlValue False (Just (TInterface n)) = do
  api <- findAPIByName n
  case api of
    APIConst _c ->
      notImplementedError "This cToOCamlValue (APIConst) isn't implemented yet"
    APIFunction _f -> notImplementedError
      "This cToOCamlValue (APIFunction) isn't implemented yet"
    APICallback _c -> notImplementedError
      "This cToOCamlValue (APICallback) isn't implemented yet"
    APIEnum _enum -> return $ "Val_" <> camelCaseToSnakeCase (name n)
    APIFlags _f ->
      notImplementedError "This cToOCamlValue (APIFlags) isn't implemented yet"
    APIInterface _i -> notImplementedError
      "This cToOCamlValue (APIInterface) isn't implemented yet"
    APIObject o -> return $ "Val_" <> objTypeName o
    APIStruct _s ->
      notImplementedError "This cToOCamlValue (APIStruct) isn't implemented yet"
    APIUnion _u ->
      notImplementedError "This cToOCamlValue (APIUnion) isn't implemented yet"
cToOCamlValue True (Just (TBasicType t)) = case t of
  TUTF8 -> return "Val_option_string"
  TFileName -> return "Val_option_string"
  TPtr -> notImplementedError "This cToOCamlValue (TPtr) isn't implemented yet"
  TIntPtr ->
    notImplementedError "This cToOCamlValue (TIntPtr) isn't implemented yet"
  TUIntPtr ->
    notImplementedError "This cToOCamlValue (TUIntPtr) isn't implemented yet"
  _ ->
    notImplementedError
      "This cToOCamlValue (BasicType) isn't implemented because this type should not be nullable"
cToOCamlValue True (Just (TError)) =
  notImplementedError "This cToOCamlValue (TError) isn't implemented yet"
cToOCamlValue True (Just (TVariant)) =
  notImplementedError "This cToOCamlValue (TVariant) isn't implemented yet"
cToOCamlValue True (Just (TParamSpec)) =
  notImplementedError "This cToOCamlValue (TParamSpec) isn't implemented yet"
cToOCamlValue True (Just (TCArray _b _i1 _i2 _t)) =
  notImplementedError "This cToOCamlValue (TCArray) isn't implemented yet"
cToOCamlValue True (Just (TGArray _t)) =
  notImplementedError "This cToOCamlValue (TGArray) isn't implemented yet"
cToOCamlValue True (Just (TPtrArray _t)) =
  notImplementedError "This cToOCamlValue (TPtrArray) isn't implemented yet"
cToOCamlValue True (Just (TByteArray)) =
  notImplementedError "This cToOCamlValue (TByteArray) isn't implemented yet"
cToOCamlValue True (Just (TGList _t)) =
  notImplementedError "This cToOCamlValue (TGList) isn't implemented yet"
cToOCamlValue True (Just (TGSList _t)) =
  notImplementedError "This cToOCamlValue (TGSList) isn't implemented yet"
cToOCamlValue True (Just (TGHash _t1 _t2)) =
  notImplementedError "This cToOCamlValue (TGHash) isn't implemented yet"
cToOCamlValue True (Just (TGClosure _m)) =
  notImplementedError "This cToOCamlValue (TGClosure) isn't implemented yet"
cToOCamlValue True (Just (TInterface n)) = do
  api <- findAPIByName n
  case api of
    APIConst _c ->
      notImplementedError "This cToOCamlValue (APIConst) isn't implemented yet"
    APIFunction _f -> notImplementedError
      "This cToOCamlValue (APIFunction) isn't implemented yet"
    APICallback _c -> notImplementedError
      "This cToOCamlValue (APICallback) isn't implemented yet"
    APIEnum _enum ->
      notImplementedError "This cToOCamlValue (Enum) isn't implemented yet"
    APIFlags _f ->
      notImplementedError "This cToOCamlValue (APIFlags) isn't implemented yet"
    APIInterface _i -> notImplementedError
      "This cToOCamlValue (APIInterface) isn't implemented yet"
    APIObject o -> do
      currMod <- currentModule
      unique  <- getFreshTypeVariable
      let currModuleName = last $ T.splitOn "." currMod
          macroName = objTypeName o <> "_" <> currModuleName <> "_" <> unique
      cline $ "Make_Val_option2(" <> objTypeName o <> ", " <> macroName <> ")"
      return $ "Val_option_" <> macroName
    APIStruct _s -> notImplementedError
      "This cToOCamlValue (APIStruct) isn't implemented yet"
    APIUnion _u ->
      notImplementedError "This cToOCamlValue (APIUnion) isn't implemented yet"
