{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module Database.Persist.Sql.Run where

import Database.Persist.Class.PersistStore
import Database.Persist.Sql.Types
import Database.Persist.Sql.Raw
import Data.Pool as P
import Control.Monad.Trans.Reader hiding (local)
import Control.Monad.Trans.Resource
import Control.Monad.Logger
import Control.Exception (onException, bracket)
import Control.Monad.IO.Unlift
import Control.Exception (mask)
import System.Timeout (timeout)
import Data.IORef (readIORef)
import qualified Data.Map as Map
import Control.Monad (liftM)

-- | Get a connection from the pool, run the given action, and then return the
-- connection to the pool.
--
-- Note: This function previously timed out after 2 seconds, but this behavior
-- was buggy and caused more problems than it solved. Since version 2.1.2, it
-- performs no timeout checks.
runSqlPool
    :: (MonadUnliftIO m, IsSqlBackend backend)
    => ReaderT backend m a -> Pool backend -> m a
runSqlPool r pconn = withRunInIO $ \run -> withResource pconn $ run . runSqlConn r

-- | Like 'withResource', but times out the operation if resource
-- allocation does not complete within the given timeout period.
--
-- @since 2.0.0
withResourceTimeout
  :: forall a m b.  (MonadUnliftIO m)
  => Int -- ^ Timeout period in microseconds
  -> Pool a
  -> (a -> m b)
  -> m (Maybe b)
{-# SPECIALIZE withResourceTimeout :: Int -> Pool a -> (a -> IO b) -> IO (Maybe b) #-}
withResourceTimeout ms pool act = withRunInIO $ \runInIO -> mask $ \restore -> do
    mres <- timeout ms $ takeResource pool
    case mres of
        Nothing -> runInIO $ return (Nothing :: Maybe b)
        Just (resource, local) -> do
            ret <- restore (runInIO (liftM Just $ act resource)) `onException`
                    destroyResource pool local resource
            putResource local resource
            return ret
{-# INLINABLE withResourceTimeout #-}

runSqlConn :: (MonadUnliftIO m, IsSqlBackend backend) => ReaderT backend m a -> backend -> m a
runSqlConn r conn = withRunInIO $ \runInIO -> mask $ \restore -> do
    let conn' = persistBackend conn
        getter = getStmtConn conn'
    restore $ connBegin conn' getter
    x <- onException
            (restore $ runInIO $ runReaderT r conn)
            (restore $ connRollback conn' getter)
    restore $ connCommit conn' getter
    return x

runSqlPersistM
    :: (IsSqlBackend backend)
    => ReaderT backend (NoLoggingT (ResourceT IO)) a -> backend -> IO a
runSqlPersistM x conn = runResourceT $ runNoLoggingT $ runSqlConn x conn

runSqlPersistMPool
    :: (IsSqlBackend backend)
    => ReaderT backend (NoLoggingT (ResourceT IO)) a -> Pool backend -> IO a
runSqlPersistMPool x pool = runResourceT $ runNoLoggingT $ runSqlPool x pool

liftSqlPersistMPool
    :: (MonadIO m, IsSqlBackend backend)
    => ReaderT backend (NoLoggingT (ResourceT IO)) a -> Pool backend -> m a
liftSqlPersistMPool x pool = liftIO (runSqlPersistMPool x pool)

withSqlPool
    :: (MonadLogger m, MonadUnliftIO m, IsSqlBackend backend)
    => (LogFunc -> IO backend) -- ^ create a new connection
    -> Int -- ^ connection count
    -> (Pool backend -> m a)
    -> m a
withSqlPool mkConn connCount f = withUnliftIO $ \u -> bracket
    (unliftIO u $ createSqlPool mkConn connCount)
    destroyAllResources
    (unliftIO u . f)

createSqlPool
    :: (MonadLogger m, MonadUnliftIO m, IsSqlBackend backend)
    => (LogFunc -> IO backend)
    -> Int
    -> m (Pool backend)
createSqlPool mkConn size = do
    logFunc <- askLogFunc
    liftIO $ createPool (mkConn logFunc) close' 1 20 size

-- NOTE: This function is a terrible, ugly hack. It would be much better to
-- just clean up monad-logger.
--
-- FIXME: in a future release, switch over to the new askLoggerIO function
-- added in monad-logger 0.3.10. That function was not available at the time
-- this code was written.
askLogFunc :: forall m. (MonadUnliftIO m, MonadLogger m) => m LogFunc
askLogFunc = withRunInIO $ \run ->
    return $ \a b c d -> run (monadLoggerLog a b c d)

withSqlConn
    :: (MonadUnliftIO m, MonadLogger m, IsSqlBackend backend)
    => (LogFunc -> IO backend) -> (backend -> m a) -> m a
withSqlConn open f = do
    logFunc <- askLogFunc
    withRunInIO $ \run -> bracket
      (open logFunc)
      close'
      (run . f)

close' :: (IsSqlBackend backend) => backend -> IO ()
close' conn = do
    readIORef (connStmtMap $ persistBackend conn) >>= mapM_ stmtFinalize . Map.elems
    connClose $ persistBackend conn
