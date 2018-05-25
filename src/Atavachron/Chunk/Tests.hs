{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module Atavachron.Chunk.Tests where

import Control.Arrow (second)
import Control.Monad
import Data.Bits
import Data.Foldable (toList)
import Data.Maybe
import Data.Monoid
import qualified Data.List as L

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as L

import qualified Data.Sequence as Seq

import qualified Streaming.Prelude as S

import Test.QuickCheck
import Test.QuickCheck.Monadic

--import Test.Tasty (TestTree, defaultMain, testGroup)
--import Test.Tasty.QuickCheck

import Crypto.Saltine
import Atavachron.Path
import Atavachron.Chunk.Builder
import Atavachron.Chunk.CDC
import Atavachron.Chunk.Process
import Atavachron.Streaming

--main = defaultMain chunkTests

main :: IO ()
main = do
    sodiumInit
    quickCheck prop_inverse
-- chunkTests = testProperties "Chunking tests" $
--   [
--   ]

-- | Test the core chunk processing functions
prop_inverse :: Property
prop_inverse =
    forAll (choose (1, 64)) $ \(cpWinSize :: Int) ->
    forAll (choose (0, 21)
        `suchThat` (\i -> shiftL 1 i >= cpWinSize)) $ \(cpLog2MinSize :: Int) ->
    forAll (choose (1, 22)
        `suchThat` (>=cpLog2MinSize)) $ \(cpLog2AvgSize :: Int) ->
    forAll (choose (2, 23)
        `suchThat` (>=cpLog2AvgSize)) $ \(cpLog2MaxSize :: Int) ->
    forAll (listOf genPath
        `suchThat` isUnique) $ \(files :: [Path Abs File]) ->

    -- NOTE: we include zero-length file content as a potential input
    forAll (vectorOf (length files) $ genPrintableByteString 0 100) $ \(bss :: [B.ByteString]) ->
    withMaxSuccess 1000 $ monadicIO $ do
    let fileData = zip files bss
        params   = CDCParams{..}
    fileData' <- run $ do
        chunkKey <- newChunkKey
        hashKey  <- newStoreIDKey
        cdcKey   <- newCDCKey
        collectByFile
            . rechunkToTags
            . S.map  decompress
            . S.map  (fromMaybe (error "decrypt failed") . decrypt chunkKey)
            . S.mapM (encrypt chunkKey)
            . S.map  compress
            . S.map  (hash hashKey)
            . rechunkCDC cdcKey params
            $ S.each (map (uncurry RawChunk) fileData)
    assert $ fileData == fileData'
  where
    isUnique xs = L.nub xs == xs

collectByFile
    :: Monad m
    => Stream' (RawChunk (Path Abs File) B.ByteString) m r
    -> m [(Path Abs File, B.ByteString)]
collectByFile str =
    map (second $ L.toStrict . B.toLazyByteString) . toList
        <$> S.fold_ f mempty id str
  where
    f (Seq.viewr -> s Seq.:> (file, bld)) (RawChunk file' bs)
        | file==file'      = s Seq.|> (file, bld <> B.byteString bs)
    f s (RawChunk file bs) = s Seq.|> (file, B.byteString bs)

genPrintableByteString :: Int -> Int -> Gen B.ByteString
genPrintableByteString minLength maxLength = do
    l <- choose (minLength, maxLength)
    Char8.pack <$> replicateM l chars
  where
    chars = elements ['a'..'z']

genPath :: Gen (Path Abs File)
genPath = makeFilePath (AbsDir mempty) <$> genPrintableByteString 8 16