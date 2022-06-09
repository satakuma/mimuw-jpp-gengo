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
  = NoReturn Pos
  | InvalidBreak Pos
  | InvalidContinue Pos
  | ZeroDivisionError Pos
  deriving (Eq, Read)

instance Show InterpretException where
  show e =
    case e of
      NoReturn p -> "Function exited without return" ++ showpos p
      InvalidBreak p -> "break statement in invalid context" ++ showpos p
      InvalidContinue p -> "continue statement in invalid context" ++ showpos p
      ZeroDivisionError p -> "Division by zero" ++ showpos p
    where
      showpos pos = case pos of
        Just p -> " @ " ++ show p
        Nothing -> ""


alloc :: InterpretM Loc
alloc = do
  (InterpreterState store _ _) <- get
  let loc = size store
  storeValue loc VVoid -- placeholder
  return loc

storeValue :: Loc -> Value -> InterpretM ()
storeValue loc v = do
  state@(InterpreterState store _ _) <- get
  put $ state { store = Map.insert loc v store }

lookupValue :: Ident -> InterpretM (Maybe Value)
lookupValue ident = do
  loc <- lookupVar ident
  case loc of
    Just loc' -> do
      (InterpreterState store _ _) <- get
      return $ Map.lookup loc' store
    _ -> return Nothing

lookupVar :: Ident -> InterpretM (Maybe Loc)
lookupVar ident = asks (Map.lookup ident)

insertVar :: Ident -> Loc -> Env -> Env
insertVar ident loc env = Map.insert ident loc env


class Executable a where
  interpret :: a -> InterpretM Value


instance Executable Program where
  interpret (Program _ tdefs) = populateAndInterpret tdefs tdefs
    where
      -- First, populate the environment with top definitions
      populateAndInterpret tdefsAll (tdef:tdefs) = do 
        loc <- alloc
        local (insertVar (getTopDefIdent tdef) loc) (populateAndInterpret tdefsAll tdefs)
      -- Next, interpret fn defs with updated environment and run main fn
      populateAndInterpret tdefsAll [] = do 
        mapM_ interpretTopDef tdefsAll
        (Just (VFn env _ block)) <- lookupValue mainFnIdent
        local (const env) (interpretFnBlock block)
      interpretTopDef tdef = do
        fn <- interpret tdef
        loc <- lookupVar (getTopDefIdent tdef)
        storeValue (fromJust loc) fn


instance Executable TopDef where
  interpret (FnDef p ident args rtype block) = do
    env <- ask
    return $ VFn env args block
  

interpretFnBlock :: Block -> InterpretM Value
interpretFnBlock block = do
  interpret block
  state@(InterpreterState _ loop returnv) <- get
  if isJust loop then
    case loop of
      Just IBreak -> throwError $ InvalidBreak (hasPosition block)
      Just IContinue -> throwError $ InvalidContinue (hasPosition block)
  else if isNothing returnv then
    throwError $ NoReturn (hasPosition block)
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
        (Just loc) <- lookupVar ident
        value <- interpret e
        storeValue loc value
        rest
      Ret p e -> do 
        value <- interpret e
        state <- get
        put (state { returnV = Just value })
        return VVoid
      SExp p e -> interpret e >> rest
      NestFn p tdef -> do
        loc <- alloc
        let changeEnv = Map.insert (getTopDefIdent tdef) loc
        fn <- local changeEnv (interpret tdef)
        storeValue loc fn
        local changeEnv rest
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
            when (i2 == 0) (throwError (ZeroDivisionError p))
            return (VInt (i1 `div` i2))
          Mod _ -> do
            when (i2 == 0) (throwError (ZeroDivisionError p))
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
      ELambda p args _ block -> do
        env <- ask
        return $ VFn env args block
      EApp p ident@(Ident name) args -> do
        f <- lookupValue ident
        case f of
          Just fn@(VFn env args' block) -> do
            env' <- foldM (\env (a, e) -> addArg env a e) env (zip args' args)
            local (const env') (interpretFnBlock block)
          Nothing -> case name of 
            "print" -> do
              value <- interpret (head args)
              liftIO $ putStr (show value)
              return VVoid
    where
      addArg :: Env -> Arg -> Expr -> InterpretM Env
      addArg env (Arg _ at ident) expr = do
        case at of
          VArg _ _ -> do
            value <- interpret expr
            loc <- alloc
            storeValue loc value
            return (Map.insert ident loc env)
          RefArg _ _ -> do
            let (EVar _ ident') = expr
            (Just loc) <- lookupVar ident'
            return (Map.insert ident loc env)
