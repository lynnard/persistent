{-# LANGUAGE ForeignFunctionInterface, DeriveDataTypeable #-}
-- | A port of the direct-sqlite package for dealing directly with
-- 'PersistValue's.
module Database.Sqlite  (
                         Connection,
                         Statement,
                         Error(..),
                         StepResult(Row,
                                    Done),
                         open,
                         close,
                         prepare,
                         step,
                         reset,
                         finalize,
                         bindBlob,
                         bindDouble,
                         bindInt,
                         bindInt64,
                         bindNull,
                         bindText,
                         bind,
                         column,
                         columns
                        )
    where

import Prelude hiding (error)
import qualified Prelude
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.UTF8 as UTF8
import Foreign
import Foreign.C
import Database.Persist.Base (PersistValue (..))
import Control.Concurrent.MVar

newtype Connection = Connection (Ptr ())
-- | The MVar is only used for insuring the statement is not double-finalized.
-- It won't stop you from using a statement after it's been finalized.
data Statement = Statement (Ptr ()) (MVar Bool)

data Error = ErrorOK
           | ErrorError
           | ErrorInternal
           | ErrorPermission
           | ErrorAbort
           | ErrorBusy
           | ErrorLocked
           | ErrorNoMemory
           | ErrorReadOnly
           | ErrorInterrupt
           | ErrorIO
           | ErrorNotFound
           | ErrorCorrupt
           | ErrorFull
           | ErrorCan'tOpen
           | ErrorProtocol
           | ErrorEmpty
           | ErrorSchema
           | ErrorTooBig
           | ErrorConstraint
           | ErrorMismatch
           | ErrorMisuse
           | ErrorNoLargeFileSupport
           | ErrorAuthorization
           | ErrorFormat
           | ErrorRange
           | ErrorNotAConnection
           | ErrorRow
           | ErrorDone
             deriving (Eq, Show)

data StepResult = Row | Done deriving (Eq, Show)

data ColumnType = IntegerColumn
                | FloatColumn
                | TextColumn
                | BlobColumn
                | NullColumn
                  deriving (Eq, Show)

decodeError :: Int -> Error
decodeError 0 = ErrorOK
decodeError 1 = ErrorError
decodeError 2 = ErrorInternal
decodeError 3 = ErrorPermission
decodeError 4 = ErrorAbort
decodeError 5 = ErrorBusy
decodeError 6 = ErrorLocked
decodeError 7 = ErrorNoMemory
decodeError 8 = ErrorReadOnly
decodeError 9 = ErrorInterrupt
decodeError 10 = ErrorIO
decodeError 11 = ErrorNotFound
decodeError 12 = ErrorCorrupt
decodeError 13 = ErrorFull
decodeError 14 = ErrorCan'tOpen
decodeError 15 = ErrorProtocol
decodeError 16 = ErrorEmpty
decodeError 17 = ErrorSchema
decodeError 18 = ErrorTooBig
decodeError 19 = ErrorConstraint
decodeError 20 = ErrorMismatch
decodeError 21 = ErrorMisuse
decodeError 22 = ErrorNoLargeFileSupport
decodeError 23 = ErrorAuthorization
decodeError 24 = ErrorFormat
decodeError 25 = ErrorRange
decodeError 26 = ErrorNotAConnection
decodeError 100 = ErrorRow
decodeError 101 = ErrorDone
decodeError i = Prelude.error $ "decodeError " ++ show i

decodeColumnType :: Int -> ColumnType
decodeColumnType 1 = IntegerColumn
decodeColumnType 2 = FloatColumn
decodeColumnType 3 = TextColumn
decodeColumnType 4 = BlobColumn
decodeColumnType 5 = NullColumn
decodeColumnType i = Prelude.error $ "decodeColumnType " ++ show i

foreign import ccall "sqlite3_errmsg"
  errmsgC :: Ptr () -> IO CString
errmsg :: Connection -> IO String
errmsg (Connection database) = do
  message <- errmsgC database
  byteString <- BS.packCString message
  return $ UTF8.toString byteString

sqlError :: Maybe Connection -> String -> Error -> IO a
sqlError maybeConnection functionName error = do
  details <- case maybeConnection of
               Just database -> do
                 details <- errmsg database
                 return $ ": " ++ details
               Nothing -> return "."
  fail $ "SQLite3 returned " ++ (show error)
         ++ " while attempting to perform " ++ functionName
         ++ details

foreign import ccall "sqlite3_open"
  openC :: CString -> Ptr (Ptr ()) -> IO Int
openError :: String -> IO (Either Connection Error)
openError path' = do
  BS.useAsCString (UTF8.fromString path')
                  (\path -> do
                     alloca (\database -> do
                               error' <- openC path database
                               error <- return $ decodeError error'
                               case error of
                                 ErrorOK -> do
                                            database' <- peek database
                                            return $ Left $ Connection database'
                                 _ -> return $ Right error))
open :: String -> IO Connection
open path = do
  databaseOrError <- openError path
  case databaseOrError of
    Left database -> return database
    Right error -> sqlError Nothing ("open " ++ show path) error

foreign import ccall "sqlite3_close"
  closeC :: Ptr () -> IO Int
closeError :: Connection -> IO Error
closeError (Connection database) = do
  error <- closeC database
  return $ decodeError error
close :: Connection -> IO ()
close database = do
  error <- closeError database
  case error of
    ErrorOK -> return ()
    _ -> sqlError (Just database) "close" error

foreign import ccall "sqlite3_prepare_v2"
  prepareC :: Ptr () -> CString -> Int -> Ptr (Ptr ()) -> Ptr (Ptr ()) -> IO Int
prepareError :: Connection -> String -> IO (Either Statement Error)
prepareError (Connection database) text' = do
  BS.useAsCString (UTF8.fromString text')
                  (\text -> do
                     alloca (\statement -> do
                               error' <- prepareC database text (-1) statement nullPtr
                               error <- return $ decodeError error'
                               case error of
                                 ErrorOK -> do
                                            statement' <- peek statement
                                            mvar <- newMVar True
                                            return $ Left $ Statement statement' mvar
                                 _ -> return $ Right error))
prepare :: Connection -> String -> IO Statement
prepare database text = do
  statementOrError <- prepareError database text
  case statementOrError of
    Left statement -> return statement
    Right error -> sqlError (Just database) ("prepare " ++ (show text)) error

foreign import ccall "sqlite3_step"
  stepC :: Ptr () -> IO Int
stepError :: Statement -> IO Error
stepError (Statement statement _) = do
  error <- stepC statement
  return $ decodeError error
step :: Statement -> IO StepResult
step statement = do
  error <- stepError statement
  case error of
    ErrorRow -> return Row
    ErrorDone -> return Done
    _ -> sqlError Nothing "step" error

foreign import ccall "sqlite3_reset"
  resetC :: Ptr () -> IO Int
resetError :: Statement -> IO Error
resetError (Statement statement _) = do
  error <- resetC statement
  return $ decodeError error
reset :: Statement -> IO ()
reset statement = do
  error <- resetError statement
  case error of
    ErrorOK -> return ()
    _ -> sqlError Nothing "reset" error

foreign import ccall "sqlite3_finalize"
  finalizeC :: Ptr () -> IO Int
finalizeError :: Statement -> IO Error
finalizeError (Statement statement mvar) = modifyMVar mvar go
  where
    go False = return (False, ErrorOK)
    go True = do
      error <- finalizeC statement
      return (False, decodeError error)
finalize :: Statement -> IO ()
finalize statement = do
  error <- finalizeError statement
  case error of
    ErrorOK -> return ()
    _ -> return () -- sqlError Nothing "finalize" error

foreign import ccall "sqlite3_bind_blob"
  bindBlobC :: Ptr () -> Int -> Ptr () -> Int -> Ptr () -> IO Int
bindBlobError :: Statement -> Int -> BS.ByteString -> IO Error
bindBlobError (Statement statement _) parameterIndex byteString = do
  size <- return $ BS.length byteString
  BS.useAsCString byteString
                  (\dataC -> do
                     error <- bindBlobC statement parameterIndex (castPtr dataC) size
                                        (intPtrToPtr (-1))
                     return $ decodeError error)
bindBlob :: Statement -> Int -> BS.ByteString -> IO ()
bindBlob statement parameterIndex byteString = do
  error <- bindBlobError statement parameterIndex byteString
  case error of
    ErrorOK -> return ()
    _ -> sqlError Nothing "bind blob" error

foreign import ccall "sqlite3_bind_double"
  bindDoubleC :: Ptr () -> Int -> Double -> IO Int
bindDoubleError :: Statement -> Int -> Double -> IO Error
bindDoubleError (Statement statement _) parameterIndex datum = do
  error <- bindDoubleC statement parameterIndex datum
  return $ decodeError error
bindDouble :: Statement -> Int -> Double -> IO ()
bindDouble statement parameterIndex datum = do
  error <- bindDoubleError statement parameterIndex datum
  case error of
    ErrorOK -> return ()
    _ -> sqlError Nothing "bind double" error

foreign import ccall "sqlite3_bind_int"
  bindIntC :: Ptr () -> Int -> Int -> IO Int
bindIntError :: Statement -> Int -> Int -> IO Error
bindIntError (Statement statement _) parameterIndex datum = do
  error <- bindIntC statement parameterIndex datum
  return $ decodeError error
bindInt :: Statement -> Int -> Int -> IO ()
bindInt statement parameterIndex datum = do
  error <- bindIntError statement parameterIndex datum
  case error of
    ErrorOK -> return ()
    _ -> sqlError Nothing "bind int" error

foreign import ccall "sqlite3_bind_int64"
  bindInt64C :: Ptr () -> Int -> Int64 -> IO Int
bindInt64Error :: Statement -> Int -> Int64 -> IO Error
bindInt64Error (Statement statement _) parameterIndex datum = do
  error <- bindInt64C statement parameterIndex datum
  return $ decodeError error
bindInt64 :: Statement -> Int -> Int64 -> IO ()
bindInt64 statement parameterIndex datum = do
  error <- bindInt64Error statement parameterIndex datum
  case error of
    ErrorOK -> return ()
    _ -> sqlError Nothing "bind int64" error

foreign import ccall "sqlite3_bind_null"
  bindNullC :: Ptr () -> Int -> IO Int
bindNullError :: Statement -> Int -> IO Error
bindNullError (Statement statement _) parameterIndex = do
  error <- bindNullC statement parameterIndex
  return $ decodeError error
bindNull :: Statement -> Int -> IO ()
bindNull statement parameterIndex = do
  error <- bindNullError statement parameterIndex
  case error of
    ErrorOK -> return ()
    _ -> sqlError Nothing "bind null" error

foreign import ccall "sqlite3_bind_text"
  bindTextC :: Ptr () -> Int -> CString -> Int -> Ptr () -> IO Int
bindTextError :: Statement -> Int -> String -> IO Error
bindTextError (Statement statement _) parameterIndex text = do
  byteString <- return $ UTF8.fromString text
  size <- return $ BS.length byteString
  BS.useAsCString byteString
                  (\dataC -> do
                     error <- bindTextC statement parameterIndex dataC size
                                        (intPtrToPtr (-1))
                     return $ decodeError error)
bindText :: Statement -> Int -> String -> IO ()
bindText statement parameterIndex text = do
  error <- bindTextError statement parameterIndex text
  case error of
    ErrorOK -> return ()
    _ -> sqlError Nothing "bind text" error

bind :: Statement -> [PersistValue] -> IO ()
bind statement sqlData = do
  mapM_ (\(parameterIndex, datum) -> do
          case datum of
            PersistInt64 int64 -> bindInt64 statement parameterIndex int64
            PersistDouble double -> bindDouble statement parameterIndex double
            PersistBool b -> bindInt64 statement parameterIndex $
                                if b then 1 else 0
            PersistString text -> bindText statement parameterIndex text
            PersistByteString blob -> bindBlob statement parameterIndex blob
            PersistNull -> bindNull statement parameterIndex
            PersistDay d -> bindText statement parameterIndex $ show d
            PersistTimeOfDay d -> bindText statement parameterIndex $ show d
            PersistUTCTime d -> bindText statement parameterIndex $ show d)
       $ zip [1..] sqlData
  return ()

foreign import ccall "sqlite3_column_type"
  columnTypeC :: Ptr () -> Int -> IO Int
columnType :: Statement -> Int -> IO ColumnType
columnType (Statement statement _) columnIndex = do
  result <- columnTypeC statement columnIndex
  return $ decodeColumnType result

foreign import ccall "sqlite3_column_bytes"
  columnBytesC :: Ptr () -> Int -> IO Int

foreign import ccall "sqlite3_column_blob"
  columnBlobC :: Ptr () -> Int -> IO (Ptr ())
columnBlob :: Statement -> Int -> IO BS.ByteString
columnBlob (Statement statement _) columnIndex = do
  size <- columnBytesC statement columnIndex
  BSI.create size (\resultPtr -> do
                     dataPtr <- columnBlobC statement columnIndex
                     if dataPtr /= nullPtr
                        then BSI.memcpy resultPtr (castPtr dataPtr) (fromIntegral size)
                        else return ())

foreign import ccall "sqlite3_column_int64"
  columnInt64C :: Ptr () -> Int -> IO Int64
columnInt64 :: Statement -> Int -> IO Int64
columnInt64 (Statement statement _) columnIndex = do
  columnInt64C statement columnIndex

foreign import ccall "sqlite3_column_double"
  columnDoubleC :: Ptr () -> Int -> IO Double
columnDouble :: Statement -> Int -> IO Double
columnDouble (Statement statement _) columnIndex = do
  columnDoubleC statement columnIndex

foreign import ccall "sqlite3_column_text"
  columnTextC :: Ptr () -> Int -> IO CString
columnText :: Statement -> Int -> IO String
columnText (Statement statement _) columnIndex = do
  text <- columnTextC statement columnIndex
  byteString <- BS.packCString text
  return $ UTF8.toString byteString

foreign import ccall "sqlite3_column_count"
  columnCountC :: Ptr () -> IO Int
columnCount :: Statement -> IO Int
columnCount (Statement statement _) = do
  columnCountC statement

column :: Statement -> Int -> IO PersistValue
column statement columnIndex = do
  theType <- columnType statement columnIndex
  case theType of
    IntegerColumn -> do
                 int64 <- columnInt64 statement columnIndex
                 return $ PersistInt64 int64
    FloatColumn -> do
                 double <- columnDouble statement columnIndex
                 return $ PersistDouble double
    TextColumn -> do
                 text <- columnText statement columnIndex
                 return $ PersistString text
    BlobColumn -> do
                 byteString <- columnBlob statement columnIndex
                 return $ PersistByteString byteString
    NullColumn -> return PersistNull

columns :: Statement -> IO [PersistValue]
columns statement = do
  count <- columnCount statement
  mapM (\i -> column statement i) [0..count-1]