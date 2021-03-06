{-|
Module: Squeal.PostgreSQL.PQ.Exception
Description: Squeal exceptions
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Squeal exceptions
-}

{-# LANGUAGE
    OverloadedStrings
  , PatternSynonyms
#-}

module Squeal.PostgreSQL.PQ.Exception
  ( SquealException (..)
  , pattern UniqueViolation
  , pattern CheckViolation
  , SQLState (..)
  , LibPQ.ExecStatus (..)
  , catchSqueal
  , handleSqueal
  , trySqueal
  , throwSqueal
  ) where

import Control.Exception (Exception)
import Data.ByteString (ByteString)
import Data.Text (Text)
import UnliftIO (MonadUnliftIO (..), catch, handle, try, throwIO)

import qualified Database.PostgreSQL.LibPQ as LibPQ

-- $setup
-- >>> import Squeal.PostgreSQL

-- | the state of LibPQ
data SQLState = SQLState
  { sqlExecStatus :: LibPQ.ExecStatus
  , sqlStateCode :: ByteString
    -- ^ https://www.postgresql.org/docs/current/static/errcodes-appendix.html
  , sqlErrorMessage :: ByteString
  } deriving (Eq, Show)

-- | `Exception`s that can be thrown by Squeal.
data SquealException
  = SQLException SQLState
  -- ^ SQL exception state
  | ConnectionException Text
  -- ^ `Database.PostgreSQL.LibPQ` function connection exception
  | DecodingException Text Text
  -- ^ decoding exception function and error message
  | ColumnsException Text LibPQ.Column
  -- ^ unexpected number of columns
  | RowsException Text LibPQ.Row LibPQ.Row
  -- ^ too few rows, expected at least and actual number of rows
  deriving (Eq, Show)
instance Exception SquealException

pattern UniqueViolation :: ByteString -> SquealException
pattern UniqueViolation msg = SQLException (SQLState LibPQ.FatalError "23505" msg)
pattern CheckViolation :: ByteString -> SquealException
pattern CheckViolation msg = SQLException (SQLState LibPQ.FatalError "23514" msg)

-- | Catch `SquealException`s.
catchSqueal
  :: MonadUnliftIO io
  => io a
  -> (SquealException -> io a) -- ^ handler
  -> io a
catchSqueal = catch

-- | Handle `SquealException`s.
handleSqueal
  :: MonadUnliftIO io
  => (SquealException -> io a) -- ^ handler
  -> io a -> io a
handleSqueal = handle

-- | `Either` return a `SquealException` or a result.
trySqueal :: MonadUnliftIO io => io a -> io (Either SquealException a)
trySqueal = try

-- | Throw `SquealException`s.
throwSqueal :: MonadUnliftIO io => SquealException -> io a
throwSqueal = throwIO
