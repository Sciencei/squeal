{-# LANGUAGE
    DataKinds
  , DerivingStrategies
  , FlexibleContexts
  , FlexibleInstances
  , GeneralizedNewtypeDeriving
  , LambdaCase
  , MultiParamTypeClasses
  , OverloadedStrings
  , PolyKinds
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.PQ.Decode
  ( DecodeValue (..)
  , FromValue (..)
  , DecodeRow (..)
  , genericRow
  , DecodeNullValue (..)
  , FromNullValue (..)
  , DecodeField (..)
  , FromField (..)
  ) where

import Control.Applicative
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.Kind
import GHC.OverloadedLabels
import GHC.TypeLits
import PostgreSQL.Binary.Decoding

-- import qualified Data.ByteString.Lazy as Lazy (ByteString)
-- import qualified Data.ByteString.Lazy as Lazy.ByteString
import qualified Data.ByteString as Strict (ByteString)
-- import qualified Data.Text.Lazy as Lazy (Text)
import qualified Data.Text as Strict (Text)
-- import qualified Data.Text as Strict.Text
import qualified Generics.SOP as SOP
import qualified Generics.SOP.Record as SOP

import Squeal.PostgreSQL.Alias
import Squeal.PostgreSQL.Schema

newtype DecodeValue (pg :: PGType) (y :: Type) = DecodeValue
  { runDecodeValue :: Value y }
  deriving newtype
    ( Functor
    , Applicative
    , Alternative
    , Monad
    , MonadPlus
    , MonadError Strict.Text )
class FromValue pg y where fromValue :: DecodeValue pg y

newtype DecodeNullValue (ty :: NullType) (y :: Type) = DecodeNullValue
  { runDecodeNullValue :: ReaderT
      (Maybe Strict.ByteString) (Except Strict.Text) y }
  deriving newtype
    ( Functor
    , Applicative
    , Alternative
    , Monad
    , MonadPlus
    , MonadError Strict.Text )
class FromNullValue ty y where fromNullValue :: DecodeNullValue ty y
instance FromValue pg y => FromNullValue ('NotNull pg) y where
  fromNullValue = DecodeNullValue . ReaderT $ \case
    Nothing -> throwError "fromField: saw NULL when expecting NOT NULL"
    Just bytestring -> liftEither $ valueParser
      (runDecodeValue (fromValue @pg)) bytestring
instance FromValue pg y => FromNullValue ('Null pg) (Maybe y) where
  fromNullValue = DecodeNullValue . ReaderT $ \case
    Nothing -> return Nothing
    Just bytestring -> liftEither . fmap Just $ valueParser
      (runDecodeValue (fromValue @pg)) bytestring

newtype DecodeField
  (ty :: (Symbol, NullType)) (y :: (Symbol, Type)) = DecodeField
    { runDecodeField :: ReaderT
        (Maybe Strict.ByteString) (Except Strict.Text) (SOP.P y) }
class FromField field y where fromField :: DecodeField field y
instance (fld0 ~ fld1, FromNullValue ty y)
  => FromField (fld0 ::: ty) (fld1 ::: y) where
    fromField = DecodeField . fmap SOP.P $
      runDecodeNullValue (fromNullValue @ty)

newtype DecodeRow (row :: RowType) (y :: Type) = DecodeRow
  { runDecodeRow :: ReaderT
      (SOP.NP (SOP.K (Maybe Strict.ByteString)) row) (Except Strict.Text) y }
  deriving newtype
    ( Functor
    , Applicative
    , Alternative
    , Monad
    , MonadPlus
    , MonadError Strict.Text )
instance {-# OVERLAPPING #-} (fld0 ~ fld1, FromNullValue ty y)
  => IsLabel fld0 (DecodeRow ((fld1 ::: ty) ': row) y) where
    fromLabel = DecodeRow . ReaderT $ \(SOP.K b SOP.:* _) ->
      runReaderT (runDecodeNullValue (fromNullValue @ty)) b
instance {-# OVERLAPPABLE #-} IsLabel fld (DecodeRow row y)
  => IsLabel fld (DecodeRow (field ': row) y) where
    fromLabel = DecodeRow . ReaderT $ \(_ SOP.:* bs) ->
      runReaderT (runDecodeRow (fromLabel @fld)) bs
genericRow ::
  ( SOP.SListI row
  , SOP.IsRecord y ys
  , SOP.AllZip FromField row ys
  ) => DecodeRow row y
genericRow
  = DecodeRow
  . ReaderT
  $ fmap SOP.fromRecord
  . SOP.hsequence'
  . SOP.htrans (SOP.Proxy @FromField) (SOP.Comp . runField)
runField
  :: forall ty y. FromField ty y
  => SOP.K (Maybe Strict.ByteString) ty
  -> Except Strict.Text (SOP.P y)
runField (SOP.K b) = runReaderT (runDecodeField (fromField @ty)) b