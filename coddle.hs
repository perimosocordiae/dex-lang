import System.Console.Haskeline
import System.Environment
import System.IO hiding (print)
import Control.Monad
import Control.Monad.State.Strict
import Control.Monad.Identity
import Control.Monad.Except
import Control.Monad.IO.Class
import Data.List hiding (lookup)
import IOSql
import Options.Applicative
import Data.Semigroup ((<>))
import Prelude hiding (lookup, print)

import qualified Parser as P
import Parser hiding (Expr (..), Pat (..), str)
import Lower
import Syntax
import Util
import Typer
import Interpreter
import FlatType

data Env = Env { varEnv  :: VarEnv
               , typeEnv :: TypeEnv
               , valEnv  :: ValEnv }

type Repl a = InputT (StateT Env IO) a

initEnv :: Env
initEnv = Env { varEnv  = initVarEnv
              , typeEnv = initTypeEnv
              , valEnv  = initValEnv }


consEnv :: (String, ClosedType, Val) -> Env -> Env
consEnv (var, ty, val) env =
  Env { varEnv  = var : varEnv  env
      , typeEnv = ty  : typeEnv env
      , valEnv  = val : valEnv  env }

evalCmd :: Command -> Repl ()
evalCmd c = case c of
  GetParse expr   -> print expr
  GetLowered expr -> lower expr >>= print
  GetType expr    -> lower expr >>= gettype >>= print
  EvalExpr expr   -> do e <- lower expr
                        t <- gettype e
                        v <- eval e
                        outputStrLn $ showVal t v
  EvalDecl pat expr -> do e <- lower expr
                          (p, vars) <- liftErr $ lowerPat pat
                          ts <- gettype e >>= liftErr . typePatMatch p
                          vs <- eval e >>= return . valPatMatch p
                          updateEnv vars ts vs

liftErr :: Show a => Either a b -> Repl b
liftErr (Left e)  = print e >> throwIO Interrupt
liftErr (Right x) = return x

catchErr :: Repl () -> Repl ()
catchErr = handleInterrupt $ return ()

lower :: P.Expr -> Repl Expr
lower expr = do
  env <- lift $ gets varEnv
  liftErr $ lowerExpr expr env

gettype :: Expr -> Repl ClosedType
gettype expr = do
  env <- lift $ gets typeEnv
  liftErr $ typeExpr expr env

eval :: Expr -> Repl Val
eval expr = do
  env <- lift $ gets valEnv
  return $ evalExpr expr env

print :: Show a => a -> Repl ()
print x = outputStrLn $ show x

updateEnv :: [VarName] -> [ClosedType] -> [Val] -> Repl ()
updateEnv vars ts vals =
  let update env = Env { varEnv  = vars ++ (varEnv  env)
                       , typeEnv = ts   ++ (typeEnv env)
                       , valEnv  = vals ++ (valEnv  env) }
  in lift $ modify update

runRepl :: Repl () -> Behavior -> Env -> IO ()
runRepl repl behavior env =
  let stateMonad = runInputTBehavior behavior defaultSettings repl
  in evalStateT stateMonad env

repl :: String -> Repl ()
repl prompt = loop
  where
    loop :: Repl ()
    loop = do
      input <- getInputLine prompt
      case input of
         Nothing -> return ()
         Just "" -> loop
         Just line -> case parseCommand line of
           Left e -> outputStrLn "Parse error:" >> print e >> loop
           Right cmd -> catchErr (evalCmd cmd) >> loop


terminalRepl :: Env -> IO ()
terminalRepl = runRepl (repl ">=> ") defaultBehavior

fileRepl :: String -> Env -> IO ()
fileRepl fname = runRepl (repl "") (useFile fname)

type ProgramSource = String
type DataSource = String
data CmdOpts = CmdOpts (Maybe ProgramSource) (Maybe DataSource)

opts :: ParserInfo CmdOpts
opts = info (p <**> helper) mempty
  where p = CmdOpts
            <$> (optional $ argument str (    metavar "FILE"
                                           <> help "Source program"))
            <*> (optional $ strOption (    long "data"
                                        <> metavar "DATA"
                                        <> help "Data source (optional)" ))

main :: IO ()
main = do
  CmdOpts fname dbname <- execParser opts
  let repl = case fname of
               Just fname -> fileRepl fname
               Nothing -> terminalRepl
  (inVal, inTy) <- case dbname of
                     Just dbname -> readDB dbname
                     Nothing -> return (unitVal, unitType)
  repl $ ("data", inTy, inVal) `consEnv` initEnv
