module Typecheck where

import           AbsGengo
import           Control.Monad.Except
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.State.Lazy
import           Data.Map
import qualified Data.Map                 as Map
import           Data.Maybe               (maybeToList)
import           Data.Void                (Void)
import           ErrM

type Env = Map Ident Type

type Result a = ReaderT Env (ExceptT Exception IO) a

data Exception
  = TypecheckError String
  deriving (Eq, Ord, Show, Read)

data Type
  = FnType [Type] Type
  | GnType [Type] Type
  | GnVType Type
  | IntType
  | StrType
  deriving (Eq, Ord, Read)

mainFnIdent = Ident "main"

typecheckProgram :: Program -> Result ()
typecheckProgram (Program []) = do
  env <- ask
  mainFn <- Map.lookup mainFnIdent env
  case mainFn of
    Just (FnType [] IntType) -> return ()
    _ -> throwError (TypecheckError "invalid main type")

typecheckProgram (Program (topdef:topdefs)) =
  let 


topdefType :: TopDef -> Type
topdefType (FnDef _ args rtype )