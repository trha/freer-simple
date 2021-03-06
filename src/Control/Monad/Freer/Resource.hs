{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wall #-}

module Control.Monad.Freer.Resource
    ( type Bracketed
    , runResource
    , bracket
    , bracket_
    , finally
    ) where

import Control.Monad.Freer.Internal
import Control.Monad.Freer.Interpretation
import Control.Monad.IO.Class ( liftIO )
import Control.Monad.Trans.Resource

import Data.Coerce
import Data.OpenUnion.Internal
import Data.Proxy

import GHC.TypeLits

data Resource r a where
  Bracket :: KnownNat (Length r')
    => (Eff r' ~> Eff r)
    -> Eff r' a
    -> (a -> Eff r' ())
    -> (a -> Eff r' b)
    -> Resource r b

type Bracketed r = Eff (Resource r ': r)

liftBracket :: forall r r'. (Eff r ~> Eff r') -> Bracketed r ~> Bracketed r'
liftBracket f (Eff m) = Eff $ \k -> m $ \u -> case decomp u of
  Left x -> usingEff k $ raise $ f $ liftEff x
  Right (Bracket z alloc dealloc doit) ->
    usingEff k $ send $ Bracket (f . z) alloc dealloc doit
{-# INLINE liftBracket #-}

raiseLast :: forall m r. Eff r ~> Eff (r :++: '[m])
raiseLast = coerce
{-# INLINE raiseLast #-}

liftZoom :: (Eff r ~> Eff '[IO]) -> Eff (r :++: '[m]) ~> Eff '[IO, m]
liftZoom f z = raiseUnder $ f $ coerce z
{-# INLINE liftZoom #-}

getLength :: forall k (r :: [k]). KnownNat (Length r) => Word
getLength = fromInteger $ natVal $ Proxy @(Length r)
{-# INLINE getLength #-}

runBracket :: Bracketed '[IO] ~> IO
runBracket (Eff m) = runResourceT $ m $ \u -> case decomp u of
  Left x -> liftIO $ extract x
  Right (Bracket z (alloc :: Eff r' a) dealloc doit) -> do
    let z' :: Eff (r' :++: '[ResourceT IO]) ~> Eff '[ResourceT IO]
        z' = interpret (send . liftIO @(ResourceT IO)) <$> liftZoom z
        liftResource :: ResourceT IO ~> Eff (r' :++: '[ResourceT IO])
        liftResource = liftEff . unsafeInj (getLength @_ @r' + 1)
    runM $ z' $ do
      a <- raiseLast @(ResourceT IO) alloc
      key <- liftResource $ register $ runM $ z $ dealloc a
      r <- raiseLast @(ResourceT IO) $ doit a
      liftResource $ release key
      pure r

-- | Run a 'Bracket' effect in terms of 'ResourceT'
--
-- Also see 'errorToExc'
runResource :: forall r.
            (Eff r ~> Eff '[IO])
            -- ^ Strategy for lowering an effect stack down to [IO].
            -- This is usually some composition of runA . runB . 'errorToExc'
            -> Bracketed r ~> IO
runResource f m = runBracket $ liftBracket f m
{-# INLINE runResource #-}

bracket :: KnownNat (Length r)
        => Eff r a
        -> (a -> Eff r ())
        -> (a -> Eff r b)
        -> Bracketed r b
bracket alloc dealloc doit = send $ Bracket id alloc dealloc doit
{-# INLINE bracket #-}

-- | Like 'bracket', but after and action don't pass parameter.
bracket_
  :: KnownNat (Length r) => Eff r a -> Eff r () -> Eff r b -> Bracketed r b
bracket_ before after action = bracket before (const after) (const action)
{-# INLINE bracket_ #-}

-- | Like 'bracket', but for the simple case of one computation to run
-- afterward.
finally :: KnownNat (Length r) => Eff r a -> Eff r () -> Bracketed r a
finally action finalizer = bracket (pure ()) (pure finalizer) (const action)
{-# INLINE finally #-}
