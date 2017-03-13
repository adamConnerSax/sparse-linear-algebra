{-# LANGUAGE FlexibleContexts #-}
{-# language TypeFamilies, FlexibleInstances, DeriveFunctor #-}
module Data.Sparse.Internal.TriMatrix where

-- import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import Data.IntMap.Strict ((!))
-- import qualified Data.Set as S
-- import qualified Data.Vector as V

import Data.Foldable (foldrM)
import Data.Maybe (fromMaybe)
-- import Data.Monoid
import Data.Complex

import Numeric.Eps
import Data.Sparse.Types
-- import Data.Sparse.Utils
import Data.Sparse.Internal.SList

import Data.VectorSpace
import Numeric.LinearAlgebra.Class
import Data.Sparse.SpMatrix (fromListSM, fromListDenseSM, insertSpMatrix, zeroSM, transposeSM)
import Data.Sparse.Common (prd, (@@!), nrows, ncols, lookupSM, extractRow, extractCol, SpVector, SpMatrix, foldlWithKeySV, (##), (#~#))

import Control.Monad.Catch (MonadThrow, throwM)
import Control.Exception.Common

import Control.Monad (when)
import Control.Monad.Trans.State (execStateT)
import Control.Iterative (modifyUntilM)

{- | triangular sparse matrix, row-major order

Intmap-of-sparse lists
* fast random access of rows
* fast consing of row elements
-}

newtype TriMatrix a = TM { unTM :: IM.IntMap (SList a)} deriving (Show, Functor)

emptyIMSL :: Int -> IM.IntMap (SList a)
emptyIMSL n = IM.fromList [(i, emptySL) | i <- [0 .. n-1]]

emptyTM :: Int -> TriMatrix a
emptyTM n = TM (emptyIMSL n)

-- | `appendIM i x im` appends an element `x` to the i'th SList in an IntMap-of-SLists structure
appendIM :: IM.Key -> (Int, a) -> IM.IntMap (SList a) -> IM.IntMap (SList a)
appendIM i x im = IM.insert i (x `consSL` e) im where
  e = fromMaybe emptySL (IM.lookup i im)


-- | Nested lookup with default value = 0
lookupWD :: Num a =>
     (irow -> mat -> Maybe row)    -- ^ row lookup
     -> (jcol -> row -> Maybe a)   -- ^ in-row lookup
     -> mat                
     -> irow
     -> jcol
     -> a
lookupWD rlu clu aa i j = fromMaybe 0 (rlu i aa >>= clu j)

 







{- | LU factorization : store L and U^T in TriMatrix format -}


lu :: (Scalar (SpVector t) ~ t, Elt t, VectorSpace (SpVector t),
      MonadThrow m, Epsilon t) =>
     SpMatrix t -> m (SpMatrix t, SpMatrix t) -- ^ L, U
lu amat = do
  let d@(m,n) = (nrows amat, ncols amat)
      q (_, _, i) = i == m
      luInit = (lmat0, umat0, 1) where
         urow0 = extractRow amat 0                 -- first row of U
         lcol0 = extractCol amat 0 ./ (urow0 @@ 0) -- first col of L, div by U00
         umat0 = foldlWithKeySV ins (emptyIMSL n) urow0 -- populate umat0
         lmat0 = IM.insert 0 (SL [(0, 1)]) l0 where     -- populate lmat0
           l0 = foldlWithKeySV ins (emptyIMSL m) lcol0 
         ins acc i x = appendIM i (0, x) acc
      luStep (lmat, umat, i) = do
          let (umat', uii) = uStep amat lmat umat i
          when (nearZero uii) $
             throwM (NeedsPivoting "LU" (unwords ["U", show (i,i)]) :: MatrixException Double)
          let lmat' = lStep amat lmat umat' uii i
          return (lmat', umat', i + 1)         
  (lfin, ufin, _) <- execStateT (modifyUntilM q luStep) luInit
  let uu = fillSM d True ufin
      ll = fillSM d False lfin
  return (ll, uu)





uStep :: (Elt a, Epsilon a) =>
     SpMatrix a
     -> IM.IntMap (SList a)
     -> IM.IntMap (SList a)
     -> IM.Key
     -> (IM.IntMap (SList a), a)   -- ^ updated U, i'th diagonal element Uii
uStep amat lmat umat i = (umat', udiag) where
  n = ncols amat
  udiag = amat@@!(i,i) - (li <.> umat ! i) -- i'th diag element of U
  li = lmat ! i                            -- i'th row of L
  umat' = foldr ins umat [i .. n-1]
  ins j acc
      | i == j   = appendIM j (i, udiag) acc
      | isNz uij = appendIM j (i, uij) acc
      | otherwise = acc where
    uij = aij - li <.> uj 
    aij = amat @@! (i,j)
    uj = umat ! j
  

lStep :: (Elt a, Epsilon a) =>
     SpMatrix a
     -> IM.IntMap (SList a)
     -> IM.IntMap (SList a)
     -> a                   -- ^ diagonal element of U (must be nonzero)
     -> IM.Key
     -> IM.IntMap (SList a) -- ^ updated L
lStep amat lmat umat udiag j = foldr ins lmat [j .. m-1] where
  m = nrows amat
  uj = umat ! j
  ins i acc
    | i == j   = appendIM i (j, 1) acc  -- write 1 on the diagonal 
    | isNz lij = appendIM i (j, lij) acc
    | otherwise = acc where
    lij = (aij - li <.> uj)/udiag
    aij = amat @@! (i,j)
    li = lmat ! i




fillSM :: (Rows, Cols) -> Bool -> IM.IntMap (SList a) -> SpMatrix a
fillSM (m,n) transpq tm = IM.foldlWithKey rowIns (zeroSM m n) tm where
  rowIns accRow i row = foldr ins accRow (unSL row) where
    ins (j, x) acc | transpq = insertSpMatrix j i x acc   -- transposed fill
                   | otherwise = insertSpMatrix i j x acc



-- test data

test mm = do
  (l, u) <- lu mm
  prd l
  prd u
  prd mm
  prd $ l #~# u

tm2, tm9 :: SpMatrix Double
tm2 = fromListDenseSM 3 [12, 6, -4, -51, 167, 24, 4, -68, -41]

tm9 = fromListSM (4, 4) [(0,0,pi), (1,1, 3), (3, 0, 23), (1,3, 45), (2,2,4), (3,2, 1), (3,1, 5), (3,3, exp 1)]

-- -- complex
tmc4, tmc5 :: SpMatrix (Complex Double)
tmc4 = fromListDenseSM 3 [3:+1, 4:+(-1), (-5):+3, 2:+2, 3:+(-2), 5:+0.2, 7:+(-2), 9:+(-1), 2:+3]

tmc5 = fromListDenseSM 4 $ zipWith (:+) [16..31] [15,14..0]


-- λ> test tmc4

-- 1.00            , _               , _               
-- 1.10 - 0.70i    , 1.00            , _               
-- -1.20 + 1.40i   , -0.56 + 1.04i   , 1.00            

-- 3.00 + 1.00i    , 2.00 + 2.00i    , 7.00 - 2.00i    
-- _               , 2.20 - 5.60i    , -0.10 - 3.70i   
-- _               , _               , 16.99 + 8.24i   