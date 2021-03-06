{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Obelisk.Frontend
  ( ObeliskWidget
  , Frontend (..)
  , runFrontend
  , runFrontendWithConfigsAndCurrentRoute
  , renderFrontendHtml
  , removeHTMLConfigs
  , FrontendMode (..)
  , module Obelisk.Frontend.Cookie
  ) where

import Prelude hiding ((.))

import Control.Category
import Control.Lens
import Control.Monad.Fix
import Control.Monad.IO.Class
import Control.Monad.Primitive
import Control.Monad.Reader
import Control.Monad.Ref
import Control.Monad.Trans.Maybe (MaybeT(..), runMaybeT)
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Functor.Sum
import Data.Map (Map)
import Data.Maybe (catMaybes)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified GHCJS.DOM as DOM
import qualified GHCJS.DOM.Types as DOM
import qualified GHCJS.DOM.History as DOM
import qualified GHCJS.DOM.Window as DOM
import Language.Javascript.JSaddle (JSM, jsNull)
import GHCJS.DOM (currentDocument)
import GHCJS.DOM.Document (getHead)
import GHCJS.DOM.Node (removeChild_)
import GHCJS.DOM.NodeList (item, getLength)
import GHCJS.DOM.ParentNode (querySelectorAll)
import Obelisk.Frontend.Cookie
import Obelisk.Route.Frontend
import Reflex.Dom.Core
import Reflex.Host.Class
import Obelisk.Configs
import Obelisk.ExecutableConfig.Inject (injectExecutableConfigs)
import qualified Obelisk.ExecutableConfig.Lookup as Lookup
import Web.Cookie

import Debug.Trace

makePrisms ''Sum

type ObeliskWidget js t route m =
  ( DomBuilder t m
  , MonadFix m
  , MonadHold t m
  , MonadSample t (Performable m)
  , MonadReflexCreateTrigger t m
  , PostBuild t m
  , PerformEvent t m
  , TriggerEvent t m
  , HasDocument m
  , MonadRef m
  , Ref m ~ Ref IO
  , MonadRef (Performable m)
  , Ref (Performable m) ~ Ref IO
  , MonadFix (Performable m)
  , PrimMonad m
  , Prerender js t m
  , PrebuildAgnostic t route m
  , PrebuildAgnostic t route (Client m)
  , HasConfigs m
  , HasCookies m
  )

type PrebuildAgnostic t route m =
  ( SetRoute t route m
  , RouteToUrl route m
  , MonadFix m
  , HasConfigs m
  , HasConfigs (Performable m)
  )

data Frontend route = Frontend
  { _frontend_head :: !(forall js t m. ObeliskWidget js t route m => RoutedT t route m ())
  , _frontend_body :: !(forall js t m. ObeliskWidget js t route m => RoutedT t route m ())
  }

baseTag :: forall route js t m. ObeliskWidget js t route m => RoutedT t route m ()
baseTag = elAttr "base" ("href" =: "/") blank --TODO: Figure out the base URL from the routes

removeHTMLConfigs :: JSM ()
removeHTMLConfigs = void $ runMaybeT $ do
  doc <- MaybeT currentDocument
  hd <- MaybeT $ getHead doc
  es <- collToList =<< querySelectorAll hd ("[data-obelisk-executable-config-inject-key]" :: Text)
  for_ es $ removeChild_ hd
  where
    collToList es = do
      len <- getLength es
      lst <- traverse (item es) $ take (fromIntegral len) $ [0..] -- fun with unsigned types ...
      pure $ catMaybes lst

setInitialRoute :: Bool -> JSM ()
setInitialRoute useHash = do
  traceM "setInitialRoute"
  window <- DOM.currentWindowUnchecked
  initialLocation <- DOM.getLocation window
  initialUri <- getLocationUri initialLocation
  history <- DOM.getHistory window
  DOM.replaceState history jsNull ("" :: Text) $ Just $
    show $ setAdaptedUriPath useHash "/" initialUri

data FrontendMode = FrontendMode
  { _frontendMode_hydrate :: Bool
    -- ^ There is already a rendering of the DOM in place; hydrate it rather
    -- than building new DOM
  , _frontendMode_adjustRoute :: Bool
    -- ^ The page can't use regular routes, so encode routes into the hash
    -- instead
  }

-- | Run the frontend, setting the initial route to "/" on platforms where no
-- route exists ambiently in the context (e.g. anything but web).
-- Selects FrontendMode based on platform; this doesn't work for jsaddle-warp
runFrontend
  :: forall backendRoute route
  .  Encoder Identity Identity (R (Sum backendRoute (ObeliskRoute route))) PageName
  -> Frontend (R route)
  -> JSM ()
runFrontend validFullEncoder frontend = do
  let mode = FrontendMode
        { _frontendMode_hydrate =
#ifdef ghcjs_HOST_OS
          True
#else
          False
#endif
        , _frontendMode_adjustRoute =
#ifdef ghcjs_HOST_OS
          False
#else
          True
#endif
        }
  configs <- liftIO Lookup.getConfigs
  when (_frontendMode_hydrate mode) removeHTMLConfigs
  -- There's no fundamental reason that adjustRoute needs to control setting the
  -- initial route and *also* the useHash parameter; that's why these are
  -- separate here.  However, currently, they are always the same.
  when (_frontendMode_adjustRoute mode) $ do
    setInitialRoute $ _frontendMode_adjustRoute mode
  runFrontendWithConfigsAndCurrentRoute mode configs validFullEncoder frontend

runFrontendWithConfigsAndCurrentRoute
  :: forall backendRoute route
  .  FrontendMode
  -> Map Text ByteString
  -> Encoder Identity Identity (R (Sum backendRoute (ObeliskRoute route))) PageName
  -> Frontend (R route)
  -> JSM ()
runFrontendWithConfigsAndCurrentRoute mode configs validFullEncoder frontend = do
  let ve = validFullEncoder . hoistParse errorLeft (prismEncoder (rPrism $ _InR . _ObeliskRoute_App))
      errorLeft = \case
        Left _ -> error "runFrontend: Unexpected non-app ObeliskRoute reached the frontend. This shouldn't happen."
        Right x -> Identity x
      w :: ( RawDocument (DomBuilderSpace (HydrationDomBuilderT s DomTimeline m)) ~ DOM.Document
           , Ref (Performable m) ~ Ref IO
           , Ref m ~ Ref IO
           , DomBuilder DomTimeline (HydrationDomBuilderT s DomTimeline m)
           , MonadHold DomTimeline m
           , MonadRef m
           , MonadRef (Performable m)
           , MonadReflexCreateTrigger DomTimeline m
           , PerformEvent DomTimeline m
           , PostBuild DomTimeline m
           , PrimMonad m
           , MonadSample DomTimeline (Performable m)
           , DOM.MonadJSM m
           , Monad (Performable (Client (HydrationDomBuilderT s DomTimeline m)))
           , MonadFix (Client (HydrationDomBuilderT s DomTimeline m))
           , MonadFix (Performable m)
           , MonadFix m
           , Prerender js DomTimeline (HydrationDomBuilderT s DomTimeline m)
           , MonadIO (Performable m)
           )
        => (forall c. HydrationDomBuilderT s DomTimeline m c -> FloatingWidget () c)
        -> (forall c. HydrationDomBuilderT s DomTimeline m c -> FloatingWidget () c)
        -> FloatingWidget () ()
      w appendHead appendBody = do
        rec switchover <- runRouteViewT ve switchover (_frontendMode_adjustRoute mode) $ do
              (switchover'', fire) <- newTriggerEvent
              mapRoutedT (mapSetRouteT (mapRouteToUrlT (appendHead . runConfigsT configs))) $ do
                -- The order here is important - baseTag has to be before headWidget!
                baseTag
                _frontend_head frontend
              mapRoutedT (mapSetRouteT (mapRouteToUrlT (appendBody . runConfigsT configs))) $ do
                _frontend_body frontend
                switchover' <- case _frontendMode_hydrate mode of
                  True -> lift $ lift $ lift $ lift $ HydrationDomBuilderT $ asks _hydrationDomBuilderEnv_switchover
                  False -> getPostBuild
                performEvent_ $ liftIO (fire ()) <$ switchover'
              pure switchover''
        pure ()
  if _frontendMode_hydrate mode
    then runHydrationWidgetWithHeadAndBody (pure ()) w
    else runImmediateWidgetWithHeadAndBody w

renderFrontendHtml
  :: ( t ~ DomTimeline
     , MonadIO m
     , widget ~ RoutedT t r (SetRouteT t r (RouteToUrlT r (ConfigsT (CookiesT (PostBuildT t (StaticDomBuilderT t (PerformEventT t DomHost)))))))
     )
  => Map Text ByteString
  -> Cookies
  -> (r -> Text)
  -> r
  -> Frontend r
  -> widget ()
  -> widget ()
  -> m ByteString
renderFrontendHtml configs cookies urlEnc route frontend headExtra bodyExtra = do
  --TODO: We should probably have a "NullEventWriterT" or a frozen reflex timeline
  html <- fmap snd $ liftIO $ renderStatic $ fmap fst $ runCookiesT cookies $ runConfigsT configs $ flip runRouteToUrlT urlEnc $ runSetRouteT $ flip runRoutedT (pure route) $
    el "html" $ do
      el "head" $ do
        baseTag
        injectExecutableConfigs configs
        _frontend_head frontend
        headExtra
      el "body" $ do
        _frontend_body frontend
        bodyExtra
  return $ "<!DOCTYPE html>" <> html
