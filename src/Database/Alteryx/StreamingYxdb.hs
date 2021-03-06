{-# LANGUAGE OverloadedStrings,RankNTypes #-}

module Database.Alteryx.StreamingYxdb
       (
        blocksToDecompressedBytes,
        blocksToRecords,
        getOneBlock,
        sinkRecords,
        getMetadata,
        readCalgaryFileNoRecords,
        recordsToBlocks,
        sourceCalgaryFileRecords,
        sourceFileBlocks,
        sourceFileRecords
       ) where

import Conduit
import Control.Applicative
import Control.Lens hiding (from, to)
import Control.Monad as M
import Control.Monad.Primitive as M
import Control.Monad.Trans.Resource
import qualified Control.Monad.Trans.State.Strict as State
import qualified Control.Newtype as NT
import Data.Array.Unboxed as A
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString as BS
import Blaze.ByteString.Builder as BSB
import Data.ByteString.Lazy as BSL
import Data.Conduit
import Data.Conduit.Binary
import Data.Conduit.Combinators as CC
import Data.Conduit.Serialization.Binary
import qualified Data.Foldable as F
import Data.Monoid
import Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.POSIX
import qualified Data.Vector as V
import System.IO

import Database.Alteryx.Serialization
import Database.Alteryx.Types

readRange :: (MonadResource m) => FilePath -> Maybe Int -> Maybe Int -> m BS.ByteString
readRange filepath from to = sourceFileRange filepath (fromIntegral <$> from) (fromIntegral <$> to) $$ fold

getMetadata :: FilePath -> IO YxdbMetadata
getMetadata filepath = runResourceT $ do
  headerBS <- readRange filepath Nothing (Just headerPageSize)
  let header = decode $ BSL.fromStrict headerBS :: Header

  recordInfoBS <- readRange filepath (Just headerPageSize) (Just $ numMetadataBytesHeader header)
  let recordInfo = decode $ BSL.fromStrict recordInfoBS :: RecordInfo

  blockIndexBS <- readRange filepath (Just $ fromIntegral $ header ^. recordBlockIndexPos) Nothing
  let blockIndex = decode $ BSL.fromStrict blockIndexBS :: BlockIndex

  return YxdbMetadata {
    _metadataHeader     = header,
    _metadataRecordInfo = recordInfo,
    _metadataBlockIndex = blockIndex
    }

readCalgaryFileNoRecords :: FilePath -> IO CalgaryFile
readCalgaryFileNoRecords filepath = do
  handle <- openBinaryFile filepath ReadMode

  headerBS <- BSL.hGet handle calgaryHeaderSize
  let header = decode $ headerBS :: CalgaryHeader

  recordInfoNumCharacters <- runGet getWord32le <$> BSL.hGet handle 4 :: IO Word32
  let recordInfoNumBytes = fromIntegral $ 2 * recordInfoNumCharacters
  recordInfoBs <- BSL.toStrict <$> BSL.hGet handle recordInfoNumBytes
  let recordInfo = decode $ seq recordInfoBs $ BSL.fromStrict recordInfoBs

  hSeek handle AbsoluteSeek $ fromIntegral $ header ^. calgaryHeaderIndexPosition
  indexBs <- BSL.hGetContents handle
  let indices = runGet getCalgaryBlockIndex indexBs :: CalgaryBlockIndex

  return CalgaryFile {
               _calgaryFileHeader   = header,
               _calgaryFileRecordInfo = recordInfo,
               _calgaryFileRecords  = [],
               _calgaryFileIndex    = indices
             }

type BlockRange = (Int, Int)
type BlockRanges = [BlockRange]

sourceFileRecords :: (MonadResource m, MonadIO m, PrimMonad m, MonadThrow m) => FilePath -> Source m Record
sourceFileRecords filename = do
  metadata <- liftIO $ getMetadata filename
  let recordInfo = metadata ^. metadataRecordInfo

  sourceFileBlocks filename metadata $= blocksToRecords recordInfo

sourceCalgaryFileBlocks :: (MonadResource m, MonadIO m) => FilePath -> Source m (V.Vector Record)
sourceCalgaryFileBlocks filepath = do
  calgaryFile <- liftIO $ readCalgaryFileNoRecords filepath
  let blockRanges = calgaryFileBlockRanges calgaryFile
      recordInfo = calgaryFile ^. calgaryFileRecordInfo
  sourceCalgaryBlocks filepath blockRanges recordInfo

sourceCalgaryFileRecords :: (MonadResource m, MonadIO m) => FilePath -> Source m Record
sourceCalgaryFileRecords filepath = do
  calgaryFile <- liftIO $ readCalgaryFileNoRecords filepath
  let blockRanges = calgaryFileBlockRanges calgaryFile
      recordInfo = calgaryFile ^. calgaryFileRecordInfo
  sourceCalgaryBlocks filepath blockRanges recordInfo $= calgaryBlock2Records recordInfo

-- TODO: This should probably yield vectors instead of individual records
calgaryBlock2Records :: (Monad m) => CalgaryRecordInfo -> Conduit (V.Vector Record) m Record
calgaryBlock2Records recordInfo = do
  mBlock <- await
  case mBlock of
    Nothing -> return ()
    Just (rs) -> V.forM_ rs yield

calgaryFileBlockRanges :: CalgaryFile -> BlockRanges
calgaryFileBlockRanges calgaryFile =
    let blockPosition = calgaryFile ^. calgaryFileHeader ^. calgaryHeaderIndexPosition
        blockIndex = calgaryFile ^. calgaryFileIndex
    in calgaryBlockIndexRanges blockPosition blockIndex

calgaryBlockIndexRanges :: Word32 -> CalgaryBlockIndex -> BlockRanges
calgaryBlockIndexRanges indexPosition (CalgaryBlockIndex indices) =
  let allButLast = V.zip indices $ V.tail indices
      lastRange = (V.last indices, fromIntegral indexPosition)
  in V.toList $
     V.map (\(a,b) -> (fromIntegral a, fromIntegral b)) $
     V.snoc allButLast lastRange

blockRanges :: YxdbMetadata -> BlockRanges
blockRanges metadata =
  let blockIndices =
        Prelude.map fromIntegral $
        A.elems $
        NT.unpack $
        metadata ^. metadataBlockIndex
      blockEnd = fromIntegral $ metadata ^. metadataHeader ^. recordBlockIndexPos
      ranges = Prelude.zip blockIndices (Prelude.tail $ blockIndices ++ return blockEnd)
  in ranges

sourceCalgaryBlock :: (MonadResource m) => FilePath -> CalgaryRecordInfo -> BlockRange -> Source m (V.Vector Record)
sourceCalgaryBlock filepath recordInfo (from, to) = do
  let numBytes = fromIntegral $ to - from
  rawBlock <- BSL.fromStrict <$> readRange filepath (Just from) (Just numBytes)
  let block = runGet (label ("yieldBlock: " ++ show (from, numBytes)) $ getOneBlockCalgaryRecords recordInfo) rawBlock
  yield block

sourceCalgaryBlocks :: (MonadResource m) => FilePath -> BlockRanges -> CalgaryRecordInfo -> Source m (V.Vector Record)
sourceCalgaryBlocks filepath ranges recordInfo = forM_ ranges $ sourceCalgaryBlock filepath recordInfo

sourceBlock :: (MonadResource m) => FilePath -> BlockRange -> Source m Block
sourceBlock  filepath (from, to) = do
  let numBytes = fromIntegral $ to - from
  rawBlock <- readRange filepath (Just from) (Just numBytes)
  let block = runGet (label ("yieldBlock: " ++ show (from, numBytes)) get) $
              BSL.fromStrict rawBlock :: Block
  yield block

sourceBlocks :: (MonadResource m) => FilePath -> BlockRanges -> Source m Block
sourceBlocks filepath ranges = forM_ ranges $ sourceBlock filepath

sourceFileBlocks :: (MonadResource m, PrimMonad m) => FilePath -> YxdbMetadata -> Source m Block
sourceFileBlocks filepath = sourceBlocks filepath . blockRanges

blocksToRecords :: (MonadThrow m) => RecordInfo -> Conduit Block m Record
blocksToRecords recordInfo =
  blocksToDecompressedBytes =$=
  conduitGet (getRecord recordInfo)

blocksToDecompressedBytes :: (MonadThrow m) => Conduit Block m BS.ByteString
blocksToDecompressedBytes = CC.concatMap (BSL.toChunks . NT.unpack)

type StatefulConduit a m b = Conduit a (State.StateT StreamingCSVStatistics m) b

recordsToBlocks :: (MonadThrow m, MonadResource m, PrimMonad m) => RecordInfo -> StatefulConduit Record m Block
recordsToBlocks recordInfo = do
  records <- CC.sinkVectorN recordsPerBlock
  if V.null records
     then return ()
     else do
       let numRecords = V.length records
           minimumBlockSize = miniblockThreshold `div` 2
           builder = F.fold $ V.map (buildRecord recordInfo) records
       lift $ State.modify (& statisticsNumRecords %~ (+numRecords))

       yield $ Block $
             toLazyByteStringWith miniblockThreshold minimumBlockSize miniblockThreshold builder BSL.empty

       recordsToBlocks recordInfo

computeHeaderFromStatistics :: StreamingCSVStatistics -> IO Header
computeHeaderFromStatistics statistics = do
    currentTime <- getCurrentTime
    return $ Header {
      _description         = "Alteryx database file generated by Michael Burge's 'yxdb-utils'",
      _fileId              = dbFileId WrigleyDb,
      _creationDate        = currentTime,
      _flags1              = 0,
      _flags2              = 0,
      _metaInfoLength      = fromIntegral $ (statistics ^. statisticsMetadataLength) `div` 2,
      _mystery             = 0,
      _spatialIndexPos     = 0,
      _recordBlockIndexPos = fromIntegral $ computeBlockIndexPositionFromStatistics statistics,
      _numRecords          = fromIntegral $ statistics ^. statisticsNumRecords,
      _compressionVersion  = 1,
      _reservedSpace       = BS.empty
    }

computeStartOfBlocksFromStatistics :: StreamingCSVStatistics -> Int
computeStartOfBlocksFromStatistics statistics =
    headerPageSize + (statistics ^. statisticsMetadataLength)

computeBlockIndexPositionFromStatistics :: StreamingCSVStatistics -> Integer
computeBlockIndexPositionFromStatistics statistics =
    let totalBytes    = Prelude.sum $ statistics ^. statisticsBlockLengths
        startOfBlocks = computeStartOfBlocksFromStatistics statistics
    in fromIntegral $ startOfBlocks + totalBytes

computeBlockIndexFromStatistics :: StreamingCSVStatistics -> BlockIndex
computeBlockIndexFromStatistics statistics =
    let startOfBlocks = computeStartOfBlocksFromStatistics statistics
        orderedBlockLengths = Prelude.reverse $ statistics ^. statisticsBlockLengths
        numBlocks = Prelude.length orderedBlockLengths
    in BlockIndex $
       listArray (0, numBlocks-1) $
       Prelude.map (fromIntegral . (startOfBlocks+)) $
       Prelude.init $
       Prelude.scanl (+) 0 orderedBlockLengths

toBS :: Binary a => a -> BS.ByteString
toBS = BSL.toStrict . runPut . put

sinkYxdbBlocks :: (MonadThrow m, MonadIO m) => Handle -> RecordInfo -> Sink Block (State.StateT StreamingCSVStatistics m) ()
sinkYxdbBlocks handle recordInfo = do
  liftIO $ BS.hPut handle $ BS.replicate headerPageSize 0
  let metadataBS = BSL.toStrict $ runPut (put recordInfo)
  liftIO $ BS.hPut handle metadataBS
  lift $ State.modify (& statisticsMetadataLength .~ BS.length metadataBS)
  let sinkOnlyBlocks = do
        mBlock <- await
        case mBlock of
          Nothing -> return ()
          Just block ->
              let bs = toByteString $ buildBlock block
                  bsLen = BS.length bs
              in do
                lift $ State.modify (& statisticsBlockLengths %~ (bsLen:))
                liftIO $ BS.hPut handle bs
                sinkOnlyBlocks

  sinkOnlyBlocks
  statistics <- lift State.get
  header <- liftIO $ computeHeaderFromStatistics statistics
  let blockIndex   = computeBlockIndexFromStatistics statistics
      headerBS     = toBS header
      blockIndexBS = toBS blockIndex
  liftIO $ do
    hSeek handle AbsoluteSeek 0
    BS.hPut handle headerBS
    hSeek handle SeekFromEnd 0
    BS.hPut handle blockIndexBS

sinkRecords :: (MonadThrow m, MonadIO m, MonadResource m, PrimMonad m) => Handle -> RecordInfo -> Sink Record m ()
sinkRecords handle recordInfo =
    evalStateC defaultStatistics $
      recordsToBlocks recordInfo =$=
      sinkYxdbBlocks handle recordInfo
