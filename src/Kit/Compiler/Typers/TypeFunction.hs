module Kit.Compiler.Typers.TypeFunction where

import Control.Monad
import Kit.Ast
import Kit.Compiler.Context
import Kit.Compiler.Module
import Kit.Compiler.Scope
import Kit.Compiler.TypeContext
import Kit.Compiler.TypedDecl
import Kit.Compiler.TypedExpr
import Kit.Compiler.Typers.Base
import Kit.Compiler.Typers.TypeExpression
import Kit.Compiler.Unify
import Kit.Compiler.Utils
import Kit.Error
import Kit.HashTable
import Kit.Parser
import Kit.Str

typeFunction
  :: CompileContext
  -> Module
  -> FunctionDefinition Expr (Maybe TypeSpec)
  -> IO ()
typeFunction ctx mod f = do
  debugLog ctx
    $  "typing function "
    ++ s_unpack (functionName f)
    ++ " in "
    ++ show mod
  tctx  <- newTypeContext []
  binding <- scopeGet (modScope mod) (functionName f)
  typed <- typeFunctionDefinition ctx tctx mod f binding
  bindToScope (modTypedContents mod)
              (functionName f)
              (DeclFunction typed)

typeFunctionDefinition
  :: CompileContext
  -> TypeContext
  -> Module
  -> FunctionDefinition Expr (Maybe TypeSpec)
  -> Binding
  -> IO (FunctionDefinition TypedExpr ConcreteType)
typeFunctionDefinition ctx tctx mod f binding = do
  let fPos = functionPos f
  let isMain =
        (functionName f == "main") && (ctxMainModule ctx == modPath mod) && not
          (ctxIsLibrary ctx)
  imports       <- getModImports ctx mod
  functionScope <- newScope
  tctx          <- newTypeContext (map modScope imports)
  args          <- forM
    (functionArgs f)
    (\arg -> do
      argType    <- resolveMaybeType ctx tctx mod (argPos arg) (argType arg)
      argDefault <- maybeConvert (typeExpr ctx tctx mod) (argDefault arg)
      return $ newArgSpec { argName    = argName arg
                          , argType    = argType
                          , argDefault = argDefault
                          , argPos     = argPos arg
                          }
    )

  forM_
    args
    (\arg -> bindToScope
      functionScope
      (argName arg)
      (newBinding ([], argName arg) VarBinding (argType arg) [] (argPos arg))
    )
  let returnType = case (bindingConcrete binding) of
        TypeFunction rt _ _ -> rt
        _                   -> throwk $ InternalError
          "Function type was unexpectedly missing from module scope"
          Nothing
  let functionTypeContext =
        (tctx { tctxScopes     = functionScope : (tctxScopes tctx)
              , tctxReturnType = Just returnType
              }
        )
  converted <- convertFunctionDefinition
    (typeExpr ctx functionTypeContext mod)
    (resolveMaybeType ctx tctx mod fPos)
    args
    returnType
    f
  -- Try to unify with void; if unification doesn't fail, we didn't encounter a return statement, so the function is void.
  unification <- unify ctx tctx mod returnType voidType
  case unification of
    TypeVarIs _ (TypeBasicType BasicTypeVoid) -> do
      resolveConstraint
        ctx
        tctx
        mod
        (TypeEq returnType
                voidType
                "Functions whose return type unifies with Void are Void"
                fPos
        )
    _ -> return ()
  return $ converted
    { functionType      = returnType
    , functionNamespace = (if isMain then [] else functionNamespace f)
    }
