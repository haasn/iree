add_mlir_library(IREELinalgExtTransforms
  ForeachThreadToAsync.cpp
  ForeachThreadToSequentialFor.cpp
  Fusion.cpp
  Tiling.cpp
  Transforms.cpp
  Utils.cpp

  PARTIAL_SOURCES_INTENDED
  DEPENDS
  mlir-headers
  IREELinalgExtDialect

  LINK_LIBS PUBLIC
  IREELinalgExtDialect

  MLIRAffineToStandard
  MLIRAsyncDialect
  MLIRSCFToControlFlow
  MLIRLinalgToLLVM
  MLIRDialectUtils
  MLIRVectorToLLVM
  MLIRMathToLLVM
  MLIRMemRefToLLVM
  MLIRIR
  MLIRMathDialect
  MLIRLinalgDialect
  MLIRLinalgTransforms
  MLIRPass
  MLIRSCFDialect
  MLIRTensorTransforms
  MLIRTransforms
)
