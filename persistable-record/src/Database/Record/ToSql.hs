{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- |
-- Module      : Database.Record.ToSql
-- Copyright   : 2013 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module defines interfaces
-- from Haskell type into list of SQL type.
module Database.Record.ToSql (
  -- * Conversion from record type into list of SQL type
  ToSqlM, RecordToSql, runFromRecord,
  createRecordToSql,

  (<&>),

  -- * Inference rules of 'RecordToSql' conversion
  ToSql (recordToSql),
  putRecord, putEmpty, fromRecord, wrapToSql,

  valueToSql,

  -- * Make parameter list for updating with key
  updateValuesByUnique',
  updateValuesByUnique,
  updateValuesByPrimary,

  untypedUpdateValuesIndex,
  unsafeUpdateValuesWithIndexes
  ) where

import Data.Array (listArray, (!))
import Data.Set (toList, fromList, (\\))
import Control.Applicative (pure)
import Control.Monad.Trans.Writer (Writer, execWriter, tell)
import Data.DList (DList)
import qualified Data.DList as DList

import Database.Record.Persistable
  (PersistableSqlType, runPersistableNullValue, PersistableType (persistableType),
   PersistableRecordWidth, runPersistableRecordWidth, PersistableWidth(persistableWidth),
   PersistableValue, persistableValue, fromValue)
import Database.Record.KeyConstraint
  (Primary, Unique, KeyConstraint, HasKeyConstraint(keyConstraint), unique, indexes)


-- | Context type to convert SQL type list.
type ToSqlM q a = Writer (DList q) a

runToSqlM :: ToSqlM q a -> [q]
runToSqlM =  DList.toList . execWriter

-- | Proof object type to convert from Haskell type 'a' into list of SQL type ['q'].
newtype RecordToSql q a = RecordToSql (a -> ToSqlM q ())

runRecordToSql :: RecordToSql q a -> a -> ToSqlM q ()
runRecordToSql (RecordToSql f) = f

-- | Finalize 'RecordToSql' record printer.
wrapToSql :: (a -> ToSqlM q ()) -> RecordToSql q a
wrapToSql =  RecordToSql

-- | Run 'RecordToSql' proof object. Convert from Haskell type 'a' into list of SQL type ['q'].
runFromRecord :: RecordToSql q a -- ^ Proof object which has capability to convert
              -> a               -- ^ Haskell type
              -> [q]             -- ^ list of SQL type
runFromRecord r = runToSqlM . runRecordToSql r

-- | Axiom of 'RecordToSql' for SQL type 'q' and Haksell type 'a'.
createRecordToSql :: (a -> [q])      -- ^ Convert function body
                  -> RecordToSql q a -- ^ Result proof object
createRecordToSql f =  wrapToSql $ tell . DList.fromList . f

-- | Derivation rule of 'RecordToSql' proof object for Haskell tuple (,) type.
(<&>) :: RecordToSql q a -> RecordToSql q b -> RecordToSql q (a, b)
ra <&> rb = RecordToSql $ \(a, b) -> do
  runRecordToSql ra a
  runRecordToSql rb b

-- | Derivation rule of 'RecordToSql' proof object for Haskell 'Maybe' type.
maybeRecord :: PersistableSqlType q -> PersistableRecordWidth a -> RecordToSql q a -> RecordToSql q (Maybe a)
maybeRecord qt w ra =  wrapToSql d  where
  d (Just r) = runRecordToSql ra r
  d Nothing  = tell $ DList.replicate (runPersistableRecordWidth w) (runPersistableNullValue qt)

infixl 4 <&>


-- | Inference rule interface for 'RecordToSql' proof object.
class ToSql q a where
  -- | Infer 'RecordToSql' proof object.
  recordToSql :: RecordToSql q a

-- | Inference rule of 'RecordToSql' proof object which can convert
--   from Haskell tuple ('a', 'b') type into list of SQL type ['q'].
instance (ToSql q a, ToSql q b) => ToSql q (a, b) where
  recordToSql = recordToSql <&> recordToSql

-- | Inference rule of 'RecordToSql' proof object which can convert
--   from Haskell 'Maybe' type into list of SQL type ['q'].
instance (PersistableType q, PersistableWidth a, ToSql q a) => ToSql q (Maybe a)  where
  recordToSql = maybeRecord persistableType persistableWidth recordToSql

-- | Inference rule of 'RecordToSql' proof object which can convert
--   from Haskell unit () type into /empty/ list of SQL type ['q'].
instance ToSql q () where
  recordToSql = wrapToSql $ \() -> tell DList.empty

-- | Run inferred 'RecordToSql' proof object.
--   Context to convert haskell record type 'a' into SQL type 'q' list.
putRecord :: ToSql q a => a -> ToSqlM q ()
putRecord =  runRecordToSql recordToSql

-- | Run 'RecordToSql' empty printer.
putEmpty :: () -> ToSqlM q ()
putEmpty =  putRecord

-- | Run inferred 'RecordToSql' proof object.
--   Convert from haskell type 'a' into list of SQL type ['q'].
fromRecord :: ToSql q a => a -> [q]
fromRecord =  runToSqlM . putRecord

-- | Derived 'RecordToSql' from persistable value.
valueToSql :: PersistableValue q a => RecordToSql q a
valueToSql =  RecordToSql $ tell . pure . fromValue persistableValue

-- | Make untyped indexes to update column from key indexes and record width.
--   Expected by update form like
--
-- /UPDATE <table> SET c0 = ?, c1 = ?, ..., cn = ? WHERE key0 = ? AND key1 = ? AND key2 = ? ... /
untypedUpdateValuesIndex :: [Int] -- ^ Key indexes
                         -> Int   -- ^ Record width
                         -> [Int] -- ^ Indexes to update other than key
untypedUpdateValuesIndex key width = otherThanKey  where
    maxIx = width - 1
    otherThanKey = toList $ fromList [0 .. maxIx] \\ fromList key

-- | Unsafely specify key indexes to convert from Haskell type `ra`
--   into SQL value `q` list expected by update form like
--
-- /UPDATE <table> SET c0 = ?, c1 = ?, ..., cn = ? WHERE key0 = ? AND key1 = ? AND key2 = ? ... /
--
--   using 'RecordToSql' proof object.
unsafeUpdateValuesWithIndexes :: RecordToSql q ra
                              -> [Int]
                              -> ra
                              -> [q]
unsafeUpdateValuesWithIndexes pr key a =
  [ valsA ! i | i <- otherThanKey ++ key ]  where
    vals = runFromRecord pr a
    width = length vals
    valsA = listArray (0, width - 1) vals
    otherThanKey = untypedUpdateValuesIndex key width

-- | Convert from Haskell type `ra` into SQL value `q` list expected by update form like
--
-- /UPDATE <table> SET c0 = ?, c1 = ?, ..., cn = ? WHERE key0 = ? AND key1 = ? AND key2 = ? ... /
--
--   using 'RecordToSql' proof object.
updateValuesByUnique' :: RecordToSql q ra
                      -> KeyConstraint Unique ra -- ^ Unique key table constraint proof object.
                      -> ra
                      -> [q]
updateValuesByUnique' pr uk = unsafeUpdateValuesWithIndexes pr (indexes uk)

-- | Convert like 'updateValuesByUnique'' using inferred 'RecordToSql' proof object.
updateValuesByUnique :: ToSql q ra
                     => KeyConstraint Unique ra -- ^ Unique key table constraint proof object.
                     -> ra
                     -> [q]
updateValuesByUnique = updateValuesByUnique' recordToSql

-- | Convert like 'updateValuesByUnique'' using inferred 'RecordToSql' and 'ColumnConstraint' proof objects.
updateValuesByPrimary :: (HasKeyConstraint Primary ra, ToSql q ra)
                      => ra -> [q]
updateValuesByPrimary =  updateValuesByUnique (unique keyConstraint)
