{-# LANGUAGE
    DataKinds
  , RankNTypes
  , TypeOperators
#-}

module Squeal.PostgreSQL.PQ.Connection where

import Control.Monad.IO.Class
import Data.ByteString (ByteString)

import qualified Generics.SOP as SOP
import qualified Database.PostgreSQL.LibPQ as LibPQ

{- | Makes a new connection to the database server.

This function opens a new database connection using the parameters taken
from the string conninfo.

The passed string can be empty to use all default parameters, or it can
contain one or more parameter settings separated by whitespace.
Each parameter setting is in the form keyword = value. Spaces around the equal
sign are optional. To write an empty value or a value containing spaces,
surround it with single quotes, e.g., keyword = 'a value'. Single quotes and
backslashes within the value must be escaped with a backslash, i.e., ' and \.

To specify the schema you wish to connect with, use type application.
-}
connectdb
  :: forall db io
   . MonadIO io
  => ByteString -- ^ conninfo
  -> io (SOP.K LibPQ.Connection db)
connectdb = fmap SOP.K . liftIO . LibPQ.connectdb

-- | Closes the connection to the server.
finish :: MonadIO io => SOP.K LibPQ.Connection db -> io ()
finish = liftIO . LibPQ.finish . SOP.unK

-- | Safely `lowerConnection` to a smaller schema.
lowerConnection
  :: SOP.K LibPQ.Connection (schema ': db)
  -> SOP.K LibPQ.Connection db
lowerConnection (SOP.K conn) = SOP.K conn