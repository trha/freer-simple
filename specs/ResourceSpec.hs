module ResourceSpec where

import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), try)
import Control.Monad.Freer.Error
import Control.Monad.Freer.Input
import Control.Monad.Freer.Output
import Control.Monad.Freer.Resource
import Data.IORef
import Test.Hspec

spec :: Spec
spec = do
  describe "bracket_" $ do
    it "runs a cleanup action on error (IORef)" $ do
      outputs <- newIORef []
      (result :: Either (ErrorException ErrorCall) ()) <-
        try
          . runResource
            ( errorThrow @ErrorCall
                . runOutputMonoidIORef @[String] outputs id
                . runInputConst "error"
            )
          $ bracket_ (output ["setup"]) (output ["teardown"])
          $ do
            output ["use"]
            msg <- input @String
            throwError $ ErrorCall msg
      readIORef outputs `shouldReturn` ["setup", "use", "teardown"]
      result `shouldBe` Left (ErrorException $ ErrorCall "error")

    it "runs a cleanup action on success (TVar)" $ do
      outputs <- newTVarIO []
      (result :: Either (ErrorException ErrorCall) ()) <-
        try
          . runResource
            ( errorThrow @ErrorCall
                . runOutputMonoidTVar @[String] outputs id
            )
          $ bracket_ (output ["setup"]) (output ["teardown"])
          $ do
            output ["use"]
            throwError (ErrorCall "error")
            output ["done"]
            `catchError` (\(ErrorCall msg) -> output [msg])
      readTVarIO outputs `shouldReturn` ["setup", "use", "error", "teardown"]
      result `shouldBe` Right ()
