{-# LANGUAGE FlexibleInstances #-}

module Interpreter where

import           AbsGengo
import           Control.Monad.Except
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Identity
import           Control.Monad.State.Lazy
import           Data.Map
import qualified Data.Map                 as Map
import           Data.Maybe               (fromJust, isJust, isNothing, maybeToList)
import           Data.Void                (Void)
import           ErrM
import           Utils

type Loc = Int
type Store = Map Loc Value
type Env = Map Ident Loc

env0 :: Env
env0 = Map.empty

data LoopInterrupt = IBreak | IContinue

data InterpreterState = InterpreterState {
  store :: Store,
  loopInterrupt :: Maybe LoopInterrupt,
  returnV :: Maybe Value
}

store0 :: InterpreterState
store0 = InterpreterState {
  store = Map.empty,
  loopInterrupt = Nothing,
  returnV = Nothing
}

type InterpretM a = ReaderT Env (StateT InterpreterState (ExceptT InterpretException IO)) a

runInterpreter :: InterpretM a -> IO (Either InterpretException a)
runInterpreter prog = runExceptT (evalStateT (runReaderT prog env0) store0)

data Value
  = VInt Integer
  | VStr String
  | VBool Bool
  | VVoid
  | VFn Env [Arg] Block
  deriving (Eq, Ord, Read)

instance Show Value where
  show v = case v of
    VInt i -> show i
    VStr s -> s
    VBool b -> show b
    _ -> undefined

data InterpretException
  = GenericException String
  deriving (Eq, Read, Show)

class Executable a where
  interpret :: a -> InterpretM Value

alloc :: InterpretM Loc
alloc = do
  (InterpreterState store _ _ ) <- get
  return (size store)

storeValue :: Loc -> Value -> InterpretM ()
storeValue loc v = do
  state@(InterpreterState store _ _ ) <- get
  put $ state { store = Map.insert loc v store }

lookupVar :: Ident -> InterpretM (Maybe Loc)
lookupVar ident = do
  env <- ask
  return $ Map.lookup ident env

lookupValue :: Ident -> InterpretM (Maybe Value)
lookupValue ident = do
  loc <- lookupVar ident
  case loc of
    Just loc' -> do
      (InterpreterState store _ _ ) <- get
      return $ Map.lookup loc' store
    _ -> return Nothing

instance Executable Program where
  interpret (Program _ []) = do
    main <- lookupValue mainFnIdent
    case main of
      Just (VFn env _ block) -> local (const env) (interpretFnBlock block)
      _ -> throwError $ GenericException "no main function"
  interpret (Program p (tdef:tdefs)) = do
    loc <- alloc
    fn <- interpret tdef
    storeValue loc fn
    local (Map.insert (getTopDefIdent tdef) loc) (interpret $ Program p tdefs)

instance Executable TopDef where
  -- interpret (GnDef p ident args rtype block) = undefined
  interpret (FnDef p ident args rtype block) = do
    env <- ask
    return $ VFn env args block
  

interpretFnBlock :: Block -> InterpretM Value
interpretFnBlock block = do
  interpret block
  state@(InterpreterState _ loop returnv) <- get
  if isJust loop then
    throwError $ GenericException "break or continue in invalid context"
  else if isNothing returnv then
    throwError $ GenericException "function exited without return"
  else do
    put (state { returnV = Nothing })
    return $ fromJust returnv

interpretLoopBlock :: Block -> InterpretM (Maybe LoopInterrupt)
interpretLoopBlock block = do
  interpret block
  state@(InterpreterState _ loop returnv) <- get
  if isJust returnv || isNothing loop then
    return Nothing
  else do
    put (state { loopInterrupt = Nothing })
    return loop

instance Executable Block where
  interpret (Block p stmts) = interpret stmts

ifNotInterrupted :: InterpretM Value -> InterpretM Value
ifNotInterrupted exec = do
  (InterpreterState _ loop returnv) <- get
  if isNothing loop && isNothing returnv then exec else return VVoid

instance Executable [Stmt] where
  interpret [] = return VVoid
  interpret (stmt:stmts) =
    case stmt of
      Empty _ -> rest
      BStmt _ block -> interpret block >> ifNotInterrupted rest
      Init p t ident e -> do
        loc <- alloc
        value <- interpret e
        storeValue loc value
        local (Map.insert ident loc) rest
      Ass p ident e -> do
        loc <- lookupVar ident
        when (isNothing loc) (throwError $ GenericException "typechecker logic error")
        value <- interpret e
        storeValue (fromJust loc) value
        rest
      Ret p e -> do 
        value <- interpret e
        state <- get
        put (state { returnV = Just value })
        return VVoid
      -- Yield p e -> undefined
      SExp p e -> interpret e >> rest
      NestFn p tdef -> do
        loc <- alloc
        fn <- interpret tdef
        storeValue loc fn
        local (Map.insert (getTopDefIdent tdef) loc) rest
      Break p -> do
        state <- get
        put (state { loopInterrupt = Just IBreak })
        return VVoid
      Continue p -> do
        state <- get
        put (state { loopInterrupt = Just IContinue })
        return VVoid
      w@(While p e block) -> do
        (VBool condition) <- interpret e
        if condition then do
          interrupt <- interpretLoopBlock block
          case interrupt of
            Just IBreak -> ifNotInterrupted rest
            _ -> ifNotInterrupted (interpret (w:stmts))
        else rest
      Cond p block -> interpret block >> ifNotInterrupted rest
    where
      rest = interpret stmts

instance Executable If where
  interpret ifStmt = case ifStmt of
    If p e block -> do
      (VBool condition) <- interpret e
      if condition then
        interpret block
      else return VVoid
    IfElse p e block elseBlock -> do
      (VBool condition) <- interpret e
      if condition then
        interpret block
      else
        interpret elseBlock

instance Executable Else where
  interpret elseStmt = case elseStmt of
    ElseBlock p block -> interpret block
    ElseIf p ifStmt -> interpret ifStmt

instance Executable Expr where
  interpret expr =
    case expr of
      EVar _ ident -> lookupValue ident >>= return . fromJust
      ELitInt _ i -> return (VInt i)
      EString _ s -> return (VStr s)
      ELitTrue _ -> return (VBool True)
      ELitFalse _ -> return (VBool False)
      Not p e -> do
        (VBool b) <- interpret e
        return (VBool (not b))
      Neg p e -> do
        (VInt i) <- interpret e
        return (VInt (-i))
      EAdd p e1 op e2 -> do
        (VInt i1) <- interpret e1
        (VInt i2) <- interpret e2
        case op of
          Plus _ -> return (VInt (i1 + i2))
          Minus _ -> return (VInt (i1 - i2))
      EMul p e1 op e2 -> do
        (VInt i1) <- interpret e1
        (VInt i2) <- interpret e2
        case op of
          Times _ -> return (VInt (i1 * i2))
          Div _ -> do
            when (i2 == 0) (throwError (GenericException "division by zero"))
            return (VInt (i1 `div` i2))
          Mod _ -> do
            when (i2 == 0) (throwError (GenericException "division by zero"))
            return (VInt (i1 `mod` i2))
      ERel p e1 op e2 -> do
        (VInt i1) <- interpret e1
        (VInt i2) <- interpret e2
        case op of
          LTH _ -> return (VBool (i1 < i2))
          LE _ -> return (VBool (i1 <= i2))
          GTH _ -> return (VBool (i1 > i2))
          GE _ -> return (VBool (i1 >= i2))
          EQU _ -> return (VBool (i1 == i2))
          NE _ -> return (VBool (i1 /= i2))
      EAnd p e1 e2 -> do
        (VBool b1) <- interpret e1
        (VBool b2) <- interpret e2
        return (VBool (b1 && b2))
      EOr p e1 e2 -> do
        (VBool b1) <- interpret e1
        (VBool b2) <- interpret e2
        return (VBool (b1 || b2))
      EApp p ident@(Ident name) args -> do
        f <- lookupValue ident
        case f of
          Just fn@(VFn env args' block) -> do
            loc <- alloc
            storeValue loc fn
            env' <- foldM (\env (a, e) -> addArg env a e) (Map.insert ident loc env) (zip args' args)
            local (const env') (interpretFnBlock block)
          Nothing -> case name of 
            "print" -> do
              value <- interpret (head args)
              liftIO $ putStr (show value)
              return VVoid
    where
      addArg :: Env -> Arg -> Expr -> InterpretM Env
      addArg env arg expr = do
        case arg of
          VArg _ _ ident -> do
            value <- interpret expr
            loc <- alloc
            storeValue loc value
            return (Map.insert ident loc env)
          RefArg _ _ ident -> do
            let (EVar _ ident') = expr
            (Just loc) <- lookupVar ident'
            return (Map.insert ident loc env)

