{-
 Copyright (c) 2012-2017 "JUSPAY Technologies"
 JUSPAY Technologies Pvt. Ltd. [https://www.juspay.in]
 This file is part of JUSPAY Platform.
 JUSPAY Platform is free software: you can redistribute it and/or modify
 it for only educational purposes under the terms of the GNU Affero General
 Public License (GNU AGPL) as published by the Free Software Foundation,
 either version 3 of the License, or (at your option) any later version.
 For Enterprise/Commerical licenses, contact <info@juspay.in>.
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  The end user will
 be liable for all damages without limitation, which is caused by the
 ABUSE of the LICENSED SOFTWARE and shall INDEMNIFY JUSPAY for such
 damages, claims, cost, including reasonable attorney fee claimed on Juspay.
 The end user has NO right to claim any indemnification based on its use
 of Licensed Software. See the GNU Affero General Public License for more details.
 You should have received a copy of the GNU Affero General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/agpl.html>.
-}

module Presto.Backend.DB
  (
    useMasterClause,
    _getModelByName,
    getModelByName,
    findOne,
    findAll,
    findAndCountAll,
    -- query,
    bCreate',
    create,
    createWithOpts,
    update,
    delete
  ) where

import Prelude

import Control.Monad.Error.Class (throwError)
import Control.Monad.Except (runExcept)
import Data.Bifunctor (bimap)
import Data.Either (Either(..), hush)
import Data.Function.Uncurried (Fn2, runFn2)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (unwrap)
import Data.Options (Options, assoc, opt, (:=))
import Effect (Effect)
import Effect.Aff (Aff, Error, attempt, error)
import Effect.Class (liftEffect)
import Foreign (readString)
import Foreign.Object (lookup)
import Sequelize.CRUD (bulkCreate, findAndCountAll')
import Sequelize.CRUD.Create as Seql
import Sequelize.CRUD.Destroy as Destroy
import Sequelize.CRUD.Read (findAll', findOne')
import Sequelize.CRUD.Update (updateModel')
import Sequelize.CRUD.Utils (mapInstanceToModel)
import Sequelize.Class (class Model, class Submodel, modelName)
import Sequelize.Connection (getConnOpts)
import Sequelize.Instance (instanceToModelE)
import Sequelize.Query.Options (returning, useMaster)
import Sequelize.Types (Conn, ModelOf)
import Type.Proxy (Proxy(..))
import Unsafe.Coerce (unsafeCoerce)

foreign import _getModelByName :: forall a. Fn2 Conn String (Effect (ModelOf a))


-- Add this clause if you want to force a query to be executed on Master DB
useMasterClause :: forall t7. Options t7
useMasterClause = (maybe mempty (assoc (opt "useMaster")) $ Just true)

getModelByName :: forall a. Model a => Conn -> Aff (Either Error (ModelOf a))
getModelByName conn = do
    let mName = modelName (Proxy :: Proxy a)
    attempt $ liftEffect $ runFn2 _getModelByName conn mName

findOne :: forall a. Model a => Conn -> Options a -> Aff (Either Error (Maybe a))
findOne conn options = do
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of 
        Right m -> do
            val <- attempt $ findOne' m options
            case val of
                Right (Just v) -> pure $ bimap (\err -> error $ show err) Just (instanceToModelE v)
                Right Nothing -> pure <<< Right $ Nothing
                Left err -> pure <<< Left $ error $ show err
        Left err -> pure $ Left $ error $ show err

-- findOneE :: forall a. Model a => Options a -> FlowES Configs _ a
-- findOneE options = do
--   conn <- get
--   model <- getModelByName :: (FlowES Configs _ (ModelOf a))
--   let mName = modelName (Proxy :: Proxy a)
--   lift $ ExceptT $ doAff do
--     val <- attempt $ findOne' model options
--     case val of
--       Right (Just v) -> pure $ bimap (\err -> DBError { message : show err  }) id (instanceToModelE v)
--       Right Nothing -> pure <<< Left $ DBError { message : mName <> " not found" }
--       Left err -> pure <<< Left $ DBError { message : show err }

findAll :: forall a. Model a => Conn -> Options a -> Aff (Either Error (Array a))
findAll conn options = do
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of
        Right m -> do
            val <- attempt $ findAll' m options
            case val of
                Right arrayRec -> pure <<< Right $ arrayRec
                Left err -> pure <<< Left $ error $ show err
        Left err -> pure $ Left $ error $ show err

findAndCountAll :: forall a. Model a => Conn -> Options a
  -> Aff (Either Error { count :: Int, rows :: Array a})
findAndCountAll conn options = do
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of
        Right m -> do
            val <- attempt $ findAndCountAll' m options
            case val of
                Right arrayRec -> pure <<< Right $ arrayRec
                Left err -> pure <<< Left $ error $ show err
        Left err -> pure $ Left $ error $ show err

-- query :: forall a. Conn -> String -> Aff (Either Error (Array a))
-- query conn rawq = do
--     val <- attempt $ query' conn rawq
--     case val of
--         Right arrayRec -> pure <<< Right $ arrayRec
--         Left err -> pure <<< Left $ error $ show err


createWithOpts :: forall a. Model a => Conn -> a -> Options a -> Aff (Either Error (Maybe a))
createWithOpts conn entity options = do
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of
        Right m -> do
            val <- attempt $ Seql.createWithOpts' m entity options
            case val of
                Right rec -> pure $ bimap (\err -> error $ show err) Just (instanceToModelE rec)
                Left err -> pure <<< Left $ error $ show err
        Left err -> pure $ Left $ error $ show err

create :: forall a. Model a => Conn -> a -> Aff (Either Error (Maybe a))
create conn entity = createWithOpts conn entity mempty

bulkCreate':: forall a b. Submodel a b => ModelOf a -> Array b->  Aff (Array b)
bulkCreate' m e = do
  rows <- bulkCreate m e
  case mapInstanceToModel rows of
    Right v -> pure v
    Left err -> (throwError <<< error <<< show) err

bCreate' :: forall a. Model a => Conn -> Array a -> Aff (Either Error (Array a))
bCreate' conn entity = do
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of
        Right m -> do
            val <- attempt $ bulkCreate' m entity
            case val of
                Right rec -> pure $ Right rec
                Left err -> pure <<< Left $ error $ show err
        Left err -> pure $ Left $ error $ show err

update :: forall a. Model a => Conn -> Options a -> Options a -> Aff (Either Error (Array a))
update conn updateValues whereC = do
    let whereClause = addReturningClause conn whereC
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of
        Right m -> do
            val <- attempt $ updateModel' m updateValues whereClause
            case getDialect conn, val of
               _, Right {affectedCount : 0, affectedRows } -> pure <<< Right $ []
               Just "postgres" , Right {affectedCount , affectedRows : Nothing } -> pure <<< Right $ []
               _ , Right {affectedCount , affectedRows : Nothing } -> do
                    recs <- findAll' m $ whereClause <> useMaster := true
                    pure <<< Right $ recs
               _, Right {affectedCount , affectedRows : Just x } -> pure <<< Right $ x
               _, Left err -> pure <<< Left $ error $ show err
        Left err -> pure $ Left $ error $ show err

delete :: forall a. Model a => Conn -> Options a -> Aff (Either Error Int)
delete conn whereClause = do
  model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
  let mName = modelName (Proxy :: Proxy a)
  case model of
    Right m -> do
      val <- attempt $ Destroy.delete m whereClause
      case val of
        Right { affectedCount : count } -> pure <<< Right $ count
        Left err -> pure $ Left $ error $ show err
    Left err -> pure $ Left $ error $ show err  

addReturningClause :: forall a. Model a => Conn -> Options a -> Options a
addReturningClause conn whereClause = case getDialect conn of
        Just "postgres" -> returning := true <> whereClause
        _ -> whereClause

getDialect :: Conn -> Maybe String
getDialect conn = maybe Nothing (hush <<< runExcept <<< readString) (lookup "dialect" $ unsafeCoerce <<< unwrap <<< getConnOpts $ conn)
