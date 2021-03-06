{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Chairman.Hedgehog.Process
  ( createProcess
  , execFlex
  , getProjectBase
  , procChairman
  , procCli
  , procNode
  , execCli
  , waitForProcess
  , waitSecondsForProcess
  ) where

import           Chairman.Hedgehog.Base (Integration)
import           Chairman.IO.Process (TimedOut (..))
import           Chairman.Plan
import           Control.Concurrent.Async
import           Control.Exception
import           Control.Monad
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Resource (ReleaseKey, register)
import           Data.Aeson (eitherDecode)
import           Data.Bool
import           Data.Either
import           Data.Eq
import           Data.Function
import           Data.Int
import           Data.Maybe (Maybe (..))
import           Data.Semigroup ((<>))
import           Data.String (String)
import           GHC.Stack (HasCallStack)
import           Prelude (error)
import           System.Exit (ExitCode)
import           System.IO (Handle)
import           System.Process (CmdSpec (..), CreateProcess (..), ProcessHandle)
import           Text.Show

import qualified Chairman.Hedgehog.Base as H
import qualified Chairman.IO.Process as IO
import qualified Data.ByteString.Lazy as LBS
import qualified Data.List as L
import qualified Data.Text as T
import qualified GHC.Stack as GHC
import qualified Hedgehog as H
import qualified System.Environment as IO
import qualified System.Exit as IO
import qualified System.Process as IO

-- | Format argument for a shell CLI command.
--
-- This includes automatically embedding string in double quotes if necessary, including any necessary escaping.
--
-- Note, this function does not cover all the edge cases for shell processing, so avoid use in production code.
argQuote :: String -> String
argQuote arg = if ' ' `L.elem` arg || '"' `L.elem` arg || '$' `L.elem` arg
  then "\"" <> escape arg <> "\""
  else arg
  where escape :: String -> String
        escape ('"':xs) = '\\':'"':escape xs
        escape ('\\':xs) = '\\':'\\':escape xs
        escape ('\n':xs) = '\\':'n':escape xs
        escape ('\r':xs) = '\\':'r':escape xs
        escape ('\t':xs) = '\\':'t':escape xs
        escape ('$':xs) = '\\':'$':escape xs
        escape (x:xs) = x:escape xs
        escape "" = ""

-- | Create a process returning handles to stdin, stdout, and stderr as well as the process handle.
createProcess :: HasCallStack
  => CreateProcess
  -> Integration (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle, ReleaseKey)
createProcess cp = GHC.withFrozenCallStack $ do
  H.annotate $ "CWD: " <> show (IO.cwd cp)
  case IO.cmdspec cp of
    RawCommand cmd args -> H.annotate $ "Command line: " <> cmd <> " " <> L.unwords args
    ShellCommand cmd -> H.annotate $ "Command line: " <> cmd
  (mhStdin, mhStdout, mhStderr, hProcess) <- H.evalM . liftIO $ IO.createProcess cp
  releaseKey <- register $ IO.cleanupProcess (mhStdin, mhStdout, mhStderr, hProcess)
  return (mhStdin, mhStdout, mhStderr, hProcess, releaseKey)



-- | Create a process returning its stdout.
--
-- Being a 'flex' function means that the environment determines how the process is launched.
--
-- When running in a nix environment, the 'envBin' argument describes the environment variable
-- that defines the binary to use to launch the process.
--
-- When running outside a nix environment, the `pkgBin` describes the name of the binary
-- to launch via cabal exec.
execFlex :: HasCallStack
  => String
  -> String
  -> [String]
  -> Integration String
execFlex pkgBin envBin arguments = GHC.withFrozenCallStack $ do
  maybeEnvBin <- liftIO $ IO.lookupEnv envBin
  (actualBin, actualArguments) <- case maybeEnvBin of
    Just envBin' -> return (envBin', arguments)
    Nothing -> return ("cabal", "exec":"--":pkgBin:arguments)
  H.annotate $ "Command: " <> actualBin <> " " <> L.unwords actualArguments
  (exitResult, stdout, stderr) <- H.evalM . liftIO $ IO.readProcessWithExitCode actualBin actualArguments ""
  case exitResult of
    IO.ExitFailure exitCode -> H.failMessage GHC.callStack . L.unlines $
      [ "Process exited with non-zero exit-code"
      , "━━━━ command ━━━━"
      , pkgBin <> " " <> L.unwords (fmap argQuote arguments)
      , "━━━━ stdout ━━━━"
      , stdout
      , "━━━━ stderr ━━━━"
      , stderr
      , "━━━━ exit code ━━━━"
      , show @Int exitCode
      ]
    IO.ExitSuccess -> return stdout

-- | Run cardano-cli, returning the stdout
execCli :: HasCallStack => [String] -> Integration String
execCli = GHC.withFrozenCallStack $ execFlex "cardano-cli" "CARDANO_CLI"

waitForProcess :: HasCallStack
  => ProcessHandle
  -> Integration (Maybe ExitCode)
waitForProcess hProcess = GHC.withFrozenCallStack $ do
  H.evalM . liftIO $ catch (fmap Just (IO.waitForProcess hProcess)) $ \(_ :: AsyncCancelled) -> return Nothing

waitSecondsForProcess :: HasCallStack
  => Int
  -> ProcessHandle
  -> Integration (Either TimedOut (Maybe ExitCode))
waitSecondsForProcess seconds hProcess = GHC.withFrozenCallStack $ do
  result <- H.evalIO $ IO.waitSecondsForProcess seconds hProcess
  case result of
    Left TimedOut -> do
      H.annotate "Timed out waiting for process to exit"
      return (Left TimedOut)
    Right maybeExitCode -> do
      case maybeExitCode of
        Nothing -> H.annotate "No exit code for process"
        Just exitCode -> H.annotate $ "Process exited " <> show exitCode
      return (Right maybeExitCode)

procDist
  :: String
  -- ^ Package name
  -> [String]
  -- ^ Arguments to the CLI command
  -> Integration CreateProcess
  -- ^ Captured stdout
procDist pkg arguments = do
  contents <- liftIO $ LBS.readFile "../dist-newstyle/cache/plan.json"

  case eitherDecode contents of
    Right plan -> case L.filter matching (plan & installPlan) of
      (component:_) -> case component & binFile of
        Just bin -> return $ IO.proc (T.unpack bin) arguments
        Nothing -> error $ "missing bin-file in: " <> show component
      [] -> error $ "Cannot find exe:" <> pkg <> " in plan"
    Left message -> error $ "Cannot decode plan: " <> message
  where matching :: Component -> Bool
        matching component = case componentName component of
          Just name -> name == "exe:" <> T.pack pkg
          Nothing -> False

procFlex
  :: HasCallStack
  => String
  -- ^ Cabal package name corresponding to the executable
  -> String
  -- ^ Environment variable pointing to the binary to run
  -> [String]
  -- ^ Arguments to the CLI command
  -> Integration CreateProcess
  -- ^ Captured stdout
procFlex pkg binaryEnv arguments = GHC.withFrozenCallStack . H.evalM $ do
  maybeEnvBin <- liftIO $ IO.lookupEnv binaryEnv
  case maybeEnvBin of
    Just envBin -> return $ IO.proc envBin arguments
    Nothing -> procDist pkg arguments

procCli
  :: HasCallStack
  => [String]
  -- ^ Arguments to the CLI command
  -> Integration CreateProcess
  -- ^ Captured stdout
procCli = procFlex "cardano-cli" "CARDANO_CLI"

procNode
  :: HasCallStack
  => [String]
  -- ^ Arguments to the CLI command
  -> Integration CreateProcess
  -- ^ Captured stdout
procNode = procFlex "cardano-node" "CARDANO_NODE"

procChairman
  :: HasCallStack
  => [String]
  -- ^ Arguments to the CLI command
  -> Integration CreateProcess
  -- ^ Captured stdout
procChairman = procFlex "cardano-node-chairman" "CARDANO_NODE_CHAIRMAN"

getProjectBase :: Integration String
getProjectBase = do
  maybeNodeSrc <- liftIO $ IO.lookupEnv "CARDANO_NODE_SRC"
  case maybeNodeSrc of
    Just path -> return path
    Nothing -> return ".."
