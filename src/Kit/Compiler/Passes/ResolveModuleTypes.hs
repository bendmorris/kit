module Kit.Compiler.Passes.ResolveModuleTypes where

import Control.Exception
import Control.Monad
import Data.IORef
import Data.List
import System.Directory
import System.FilePath
import Kit.Ast
import Kit.Compiler.Binding
import Kit.Compiler.Context
import Kit.Compiler.Module
import Kit.Compiler.Scope
import Kit.Compiler.TypeContext
import Kit.Compiler.TypedDecl
import Kit.Compiler.TypedExpr
import Kit.Compiler.Typers.ConvertExpr
import Kit.Compiler.Unify
import Kit.Compiler.Utils
import Kit.Error
import Kit.HashTable
import Kit.Log
import Kit.Parser
import Kit.Str

data DuplicateSpecializationError = DuplicateSpecializationError ModulePath TypePath Span Span deriving (Eq, Show)
instance Errable DuplicateSpecializationError where
  logError e@(DuplicateSpecializationError mod tp pos1 pos2) = do
    logErrorBasic e $ "Duplicate specialization for `" ++ s_unpack (showTypePath tp) ++ "` in " ++ s_unpack (showModulePath mod) ++ "; \n\nFirst specialization:"
    ePutStrLn "\nSecond specialization:"
    displayFileSnippet pos2
    ePutStrLn "\nTraits cannot have overlapping specializations."
  errPos (DuplicateSpecializationError _ _ pos _) = Just pos

{-
  This step is responsible for actions that depend on the interfaces created
  during BuildModuleGraph, including:

  - Discovering trait implementations and specializations
  - Unifying module interface type vars with actual type annotations
-}
resolveModuleTypes
  :: CompileContext
  -> [(Module, [Declaration Expr (Maybe TypeSpec)])]
  -> IO [(Module, [TypedDecl])]
resolveModuleTypes ctx modContents = do
  unless (ctxIsLibrary ctx) $ validateMain ctx
  forM modContents $ resolveTypesForMod ctx

validateMain :: CompileContext -> IO ()
validateMain ctx = do
  mod  <- getMod ctx (ctxMainModule ctx)
  main <- resolveLocal (modScope mod) "main"
  case main of
    Just (Binding { bindingType = FunctionBinding f }) -> do
      -- TODO
      return ()
    _ -> throwk $ BasicError
      (show mod
      ++ " doesn't have a function called 'main'; main module requires a main function"
      )
      (Nothing)

resolveTypesForMod
  :: CompileContext
  -> (Module, [Declaration Expr (Maybe TypeSpec)])
  -> IO (Module, [TypedDecl])
resolveTypesForMod ctx (mod, contents) = do
  specs <- readIORef (modSpecializations mod)
  forM_ specs (addSpecialization ctx mod)
  impls <- readIORef (modImpls mod)
  forM_ impls (addImplementation ctx mod)
  tctx <- modTypeContext ctx mod

  let varConverter =
        converter (convertExpr ctx tctx mod) (resolveMaybeType ctx tctx mod)
  -- TODO: params
  let paramConverter params = varConverter

  converted <- forM
    contents
    (\decl -> do
      binding <- scopeGet (modScope mod) (declName decl)
      case (bindingType binding, decl) of
        (VarBinding vi, DeclVar v) -> do
          converted <- convertVarDefinition varConverter v
          mergeVarInfo ctx tctx mod vi converted
          bindToScope (modScope mod)
                      (declName decl)
                      (binding { bindingType = VarBinding converted })
          return $ DeclVar converted

        (FunctionBinding fi, DeclFunction f) -> do
          converted <- convertFunctionDefinition paramConverter f
          mergeFunctionInfo ctx tctx mod fi converted
          bindToScope (modScope mod)
                      (declName decl)
                      (binding { bindingType = FunctionBinding converted })
          return $ DeclFunction converted

        (TypeBinding ti, DeclType t) -> do
          converted <- convertTypeDefinition paramConverter t
          forM_ (zip (typeStaticFields ti) (typeStaticFields converted))
                (\(field1, field2) -> mergeVarInfo ctx tctx mod field1 field2)
          forM_
            (zip (typeStaticMethods ti) (typeStaticMethods converted))
            (\(method1, method2) ->
              mergeFunctionInfo ctx tctx mod method1 method2
            )
          case (typeSubtype ti, typeSubtype converted) of
            (Struct { structFields = fields1 }, Struct { structFields = fields2 })
              -> forM_
                (zip fields1 fields2)
                (\(field1, field2) -> mergeVarInfo ctx tctx mod field1 field2)
            (Union { unionFields = fields1 }, Union { unionFields = fields2 })
              -> forM_
                (zip fields1 fields2)
                (\(field1, field2) -> mergeVarInfo ctx tctx mod field1 field2)
            _ -> return ()

          bindToScope (modScope mod)
                      (declName decl)
                      (binding { bindingType = TypeBinding converted })
          return $ DeclType converted

        (TraitBinding ti, DeclTrait t) -> do
          converted <- convertTraitDefinition paramConverter t
          -- TODO: unify
          bindToScope (modScope mod)
                      (declName decl)
                      (binding { bindingType = TraitBinding converted })
          return $ DeclTrait converted

        (RuleSetBinding ri, DeclRuleSet r) -> do
          converted <- convertRuleSet varConverter r
          bindToScope (modScope mod)
                      (declName decl)
                      (binding { bindingType = RuleSetBinding converted })
          return $ DeclRuleSet converted
    )

  return (mod, converted)

addSpecialization
  :: CompileContext -> Module -> ((TypeSpec, TypeSpec), Span) -> IO ()
addSpecialization ctx mod (((TypeSpec tp params _), b), pos) = do
  tctx  <- newTypeContext []
  found <- resolveModuleBinding ctx tctx mod tp
  case found of
    Just (Binding { bindingType = TraitBinding _, bindingConcrete = TypeTraitConstraint (tp, params') })
      -> do
      -- TODO: params
        existing <- h_lookup (ctxTraitSpecializations ctx) tp
        case existing of
          Just (_, pos') ->
            -- if this specialization comes from a prelude, it could show up
            -- multiple times, so just ignore it
                            if pos' == pos
            then return ()
            else throwk $ DuplicateSpecializationError (modPath mod) tp pos' pos
          _ -> h_insert (ctxTraitSpecializations ctx) tp (b, pos)
    _ -> throwk $ BasicError ("Couldn't resolve trait: " ++ show tp) (Just pos)

addImplementation
  :: CompileContext
  -> Module
  -> TraitImplementation Expr (Maybe TypeSpec)
  -> IO ()
addImplementation ctx mod impl@(TraitImplementation { implTrait = Just (TypeSpec tpTrait paramsTrait posTrait), implFor = Just implFor })
  = do
    tctx       <- newTypeContext []
    foundTrait <- resolveModuleBinding ctx tctx mod (tpTrait)
    case foundTrait of
      Just (Binding { bindingType = TraitBinding _, bindingConcrete = TypeTraitConstraint (tpTrait, tpParams) })
        -> do
          ct       <- resolveType ctx tctx mod implFor
          existing <- h_lookup (ctxImpls ctx) tpTrait
          case existing of
            Just ht -> h_insert ht ct impl
            Nothing -> do
              impls <- h_new
              h_insert impls          ct      impl
              h_insert (ctxImpls ctx) tpTrait impls
      _ -> throwk $ BasicError ("Couldn't resolve trait: " ++ show tpTrait)
                               (Just posTrait)

mergeVarInfo ctx tctx mod var1 var2 = resolveConstraint
  ctx
  tctx
  mod
  (TypeEq (varType var1)
          (varType var2)
          "Var type must match its annotation"
          (varPos var1)
  )

mergeFunctionInfo ctx tctx mod f1 f2 = do
  resolveConstraint
    ctx
    tctx
    mod
    (TypeEq (functionType f1)
            (functionType f2)
            "Function return type must match its annotation"
            (functionPos f1)
    )
  forM
    (zip (functionArgs f1) (functionArgs f2))
    (\(arg1, arg2) -> do
      resolveConstraint
        ctx
        tctx
        mod
        (TypeEq (argType arg1)
                (argType arg2)
                "Function argument type must match its annotation"
                (argPos arg1)
        )
    )
