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
    -- query,
    create,
    createWithOpts,
    update,
    update',
    delete
  ) where

import Prelude

import Data.Bifunctor (bimap)
import Data.Either (Either(..))
import Data.Function.Uncurried (Fn2, runFn2)
import Data.Maybe (Maybe(..), maybe)
import Data.Options (Options, assoc, opt)
import Effect (Effect)
import Effect.Aff (Aff, Error, attempt, error)
import Effect.Class (liftEffect)
import Sequelize.CRUD (updateModel)
import Sequelize.CRUD.Create as Seql
import Sequelize.CRUD.Destroy as Destroy
import Sequelize.CRUD.Read (findAll', findOne')
import Sequelize.Class (class Model, modelName)
import Sequelize.Instance (instanceToModelE)
import Sequelize.Types (Conn, ModelOf)
import Type.Proxy (Proxy(..))

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

update :: forall a. Model a => Conn -> Options a -> Options a -> Aff (Either Error (Array a))
update conn updateValues whereClause = do
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of
        Right m -> do
            val <- update' conn updateValues whereClause
            recs <- findAll' m (whereClause <> useMasterClause)
            case val of
                Right _ -> pure <<< Right $ recs
                Left err -> pure <<< Left $ err
        Left err -> pure $ Left $ error $ show err

update' :: forall a. Model a => Conn -> Options a -> Options a -> Aff (Either Error Int)
update' conn updateValues whereClause = do
    model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
    case model of
        Right m -> do
            val <- attempt $ updateModel m updateValues whereClause
            case val of
                Right {affectedCount} -> pure <<< Right $ affectedCount
                Left err -> pure <<< Left $ error $ show err
        Left err -> pure $ Left $ error $ show err

-- updateE :: forall a. Model a => Options a -> Options a -> FlowES Configs _ (Array a)
-- updateE updateValues whereClause = do
--   { conn } <- get
--   model <- getModelByName :: (FlowES Configs _ (ModelOf a))
--   let mName = modelName (Proxy :: Proxy a)
--   lift $ ExceptT $ doAff do
--     val <- attempt $ updateModel model updateValues whereClause
--     recs <- Read.findAll' model whereClause
--     case val of
--       Right { affectedCount : 0, affectedRows } -> pure <<< Left $ DBError { message : "No record updated " <> mName }
--       Right { affectedCount , affectedRows : Nothing } -> pure <<< Left $ DBError { message : "No record updated " <> mName }
--       Right { affectedCount , affectedRows : Just x } -> pure <<< Right $ recs
--       Left err -> pure <<< Left $ DBError { message : message err }

delete :: forall a. Model a => Conn -> Options a -> Aff (Either Error Int)
delete conn whereClause = do
  model <- getModelByName conn :: (Aff (Either Error (ModelOf a)))
  let mName = modelName (Proxy :: Proxy a)
  case model of
    Right m -> do
      val <- attempt $ Destroy.delete m whereClause
      case val of
        Right { affectedCount : count } -> pure <<< Right $ count
        Left err ->pure $ Left $ error $ show err
    Left err -> pure $ Left $ error $ show err  
