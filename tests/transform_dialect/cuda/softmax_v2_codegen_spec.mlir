// RUN: iree-opt %s

// Codegen
transform.sequence failures(propagate) {
^bb1(%variant_op: !pdl.operation):
  %ops = transform.structured.match ops{["linalg.fill", "linalg.generic"]}
    in %variant_op : (!pdl.operation) -> !pdl.operation
  %input_max_fill,
  %input_max,
  %exps_sum_fill,
  %exp_and_exps_sum,
  %div = transform.split_handle %ops
    : (!pdl.operation) -> (!pdl.operation, !pdl.operation, !pdl.operation,
                           !pdl.operation, !pdl.operation)

  // Step 1. First level of tiling + fusion parallelizes to blocks.
  // ==============================================================
  %forall, %_ =
  transform.structured.tile_to_forall_op %div tile_sizes [1, 4]
    ( mapping = [#gpu.block<x>, #gpu.block<y>] )
  transform.iree.populate_workgroup_count_region_using_num_threads_slice %forall : (!pdl.operation) -> ()

  // TODO: Merging and fusing merged handles does not work properly atm.
  transform.structured.fuse_into_containing_op %exp_and_exps_sum into %forall
  transform.structured.fuse_into_containing_op %exps_sum_fill into %forall
  transform.structured.fuse_into_containing_op %input_max into %forall
  transform.structured.fuse_into_containing_op %input_max_fill into %forall
  // By default, fusion into scf.forall does not promote captured values
  // to shared as this involves a cross-thread dependence analysis.
  // Instead, we activate it explicitly post-hoc to promote all the extract_slice
  // ops that we find and match the prerequisites
  %forall_with_type = transform.cast %forall : !pdl.operation to !transform.op<"scf.forall">
  transform.iree.share_forall_operands %forall_with_type
    : (!transform.op<"scf.forall">) -> !transform.op<"scf.forall">

  // Canonicalizations.
  transform.iree.apply_patterns %variant_op
    { canonicalization, tiling_canonicalization, licm, cse } : (!pdl.operation) -> ()


  // Step 2. Second level of tiling + fusion parallelizes to threads.
  // ================================================================
  %tiled_ops = transform.structured.match ops{["linalg.fill", "linalg.generic"]}
    in %variant_op : (!pdl.operation) -> !pdl.operation
  %tiled_input_max_fill,
  %tiled_input_max,
  %tiled_exps_sum_fill,
  %tiled_exp_and_exps_sum,
  %tiled_div = transform.split_handle %tiled_ops
    : (!pdl.operation) -> (!pdl.operation, !pdl.operation, !pdl.operation,
                           !pdl.operation, !pdl.operation)
  // Leaving the reduction untiled on threadIdx.x makes it sequential on
  // threadIdx.x. After distribution, predication by `if (threadIdx.x == 0)` is
  // introduced and opportunities for distributing vector ops across warps
  // appear.
  %reduction_linalg_ops = transform.merge_handles %tiled_input_max,
                                                  %tiled_exp_and_exps_sum
    : !pdl.operation
  transform.structured.tile_to_forall_op %reduction_linalg_ops tile_sizes [1, 1]
    ( mapping = [#gpu.thread<z>, #gpu.thread<y>] )
  // Fully parallel ops are tiled and mapped.
  %parallel_linalg_ops = transform.merge_handles %tiled_input_max_fill,
                                                 %tiled_exps_sum_fill,
                                                 %tiled_div
    : !pdl.operation
  transform.structured.tile_to_forall_op %parallel_linalg_ops num_threads [1, 4, 32]
    ( mapping = [#gpu.thread<z>, #gpu.thread<y>, #gpu.thread<x>] )

  // Canonicalizations.
  transform.iree.apply_patterns %variant_op
    { canonicalization, tiling_canonicalization, licm, cse } : (!pdl.operation) -> ()

  // Step 3. Rank-reduce and vectorize.
  // ==================================
  %funcx_2 = transform.structured.match ops{["func.func"]} in %variant_op : (!pdl.operation) -> !pdl.operation
  transform.iree.apply_patterns %funcx_2 {  rank_reducing_linalg, rank_reducing_vector } : (!pdl.operation) -> ()
  transform.structured.vectorize %funcx_2

  // Step 4. Bufferize and drop HAL decriptor from memref ops.
  // =========================================================
  transform.iree.eliminate_empty_tensors %variant_op : (!pdl.operation) -> ()
  %variant_op_3 = transform.iree.bufferize { target_gpu } %variant_op : (!pdl.operation) -> !pdl.operation
  %memref_func = transform.structured.match ops{["func.func"]} in %variant_op_3 : (!pdl.operation) -> !pdl.operation
  transform.iree.erase_hal_descriptor_type_from_memref %memref_func : (!pdl.operation) -> ()

  // Step 5. Post-bufferization mapping to blocks and threads.
  // =========================================================
  transform.iree.forall_to_workgroup %memref_func : (!pdl.operation) -> ()
  transform.iree.map_nested_forall_to_gpu_threads %memref_func
    workgroup_dims = [32, 4, 1] : (!pdl.operation) -> ()

  // Step 6. Post-bufferization vector distribution with rank-reduction.
  // ===================================================================
  transform.iree.apply_patterns %memref_func { rank_reducing_linalg, rank_reducing_vector, fold_memref_aliases } : (!pdl.operation) -> ()
  %if_op = transform.structured.match ops{["scf.if"]} in %variant_op_3
    : (!pdl.operation) -> !pdl.operation
  %warp = transform.iree.vector.to_warp_execute_on_lane_0 %if_op { warp_size = 32 }
  transform.iree.vector.warp_distribute %memref_func
    : (!pdl.operation) -> ()


  // Late canonicalizations.
  transform.iree.apply_patterns %variant_op_3
    { canonicalization, tiling_canonicalization, licm, cse } : (!pdl.operation) -> ()
}
