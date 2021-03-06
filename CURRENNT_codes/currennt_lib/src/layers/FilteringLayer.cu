/******************************************************************************
 * This file is an addtional component of CURRENNT. 
 * Xin WANG
 * National Institute of Informatics, Japan
 * 2016
 *
 * This file is part of CURRENNT. 
 *
 * CURRENNT is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * CURRENNT is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with CURRENNT.  If not, see <http://www.gnu.org/licenses/>.
 *****************************************************************************//*

*/


#ifdef _MSC_VER
#   pragma warning (disable: 4244) // thrust/iterator/iterator_adaptor.h(121): warning C4244: '+=' : conversion from '__int64' to 'int', possible loss of data
#endif

#include "FilteringLayer.hpp"

#include "../helpers/getRawPointer.cuh"
#include "../helpers/Matrix.hpp"
#include "../helpers/min.cuh"
#include "../helpers/max.cuh"
#include "../helpers/safeExp.cuh"
#include "../helpers/NumericLimits.cuh"
#include "../helpers/JsonClasses.hpp"
#include "../helpers/misFuncs.hpp"

#include "../activation_functions/Tanh.cuh"
#include "../activation_functions/Logistic.cuh"
#include "../activation_functions/Identity.cuh"
#include "../activation_functions/Relu.cuh"

#include "../Configuration.hpp"

#include <boost/foreach.hpp>
#include <boost/random/normal_distribution.hpp>
#include <boost/random/uniform_real_distribution.hpp>
#include <boost/random/mersenne_twister.hpp>
#include <boost/algorithm/string.hpp>
#include <boost/lexical_cast.hpp>

#include <thrust/reduce.h>
#include <thrust/transform.h>
#include <thrust/transform_reduce.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/random.h>

#include <sstream>
#include <fstream>
#include <cmath>

#define FILTERING_LAYER_MODE_NONE_SELECTIVE 0
#define FILTERING_LAYER_MODE_SELECTIVE 1
#define FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS 2
#define FILTERING_LAYER_REVERB 3

#define FILTERING_LAYER_REVERB_IR_THRESHOD 0.001

namespace internal{
namespace {
    
    struct genNoise
    {
	float a, b;
	int   seed;
	
	__host__ __device__
	genNoise(float _a=-1.f, float _b=1.f, int _seed=123) : a(_a), b(_b), seed(_seed) {};

	__host__ __device__
	float operator()(const unsigned int n) const
	{
	    thrust::default_random_engine rng(seed);
	    thrust::uniform_real_distribution<float> dist(a, b);
	    rng.discard(n);
	    return dist(rng);
	}
    };

    // Use one group of filters, do filtering
    struct causalFilteringForward_none_selective
    {
	int        filterLength;             // length of filter
	int        filterShareAcrossDim;     // whether the filter is shared across data dimension
	int        layerSize;                // layer size
	int        parallel;                 
	int        initSmooth;
	int        noncausal;
	int        maxLength;
	
	real_t     *inputData;
	real_t     *filterCoeffs;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize;  // dimension index
	    int timeIdx    = outputIdx / layerSize;  // time index (regardless of parallel)
	    
	    int BlockIdx   = timeIdx / parallel;     // time index (considering parallel mode)
	    int BlockInIdx = timeIdx % parallel;     // index within a parallel block


	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff = 1.0;  
	    real_t lastValidValue = 0.0;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer

	    // for noncausal filter, shift the time index
	    if (noncausal)
		filter_idx_shift = filterLength / 2;
	    
	    for (int idx = 0 ; idx < filterLength; idx++){
		    
		// get the filter coefficient for one step
		// a_0 + a_1 z^-1 + ... + a_N z^-N
		// [a_0, a_1, ..., a_N]
		if (filterShareAcrossDim)
		    filterCoeff = filterCoeffs[idx];
		else
		    filterCoeff = filterCoeffs[dimIdx * filterLength + idx];

		// time index (of parallel block)
		data_time_idx = BlockIdx - idx + filter_idx_shift;
		// time index (abosolute time step in memory buffer)
		data_mem_idx = data_time_idx * parallel + BlockInIdx;
		
		if (data_time_idx >= 0 && data_mem_idx < maxLength &&
		    patTypes[data_mem_idx] != PATTYPE_NONE){
		    // when this time step is [0, max_length) and valid
		    tmp += inputData[data_mem_idx * layerSize + dimIdx] * filterCoeff;
		    lastValidValue = inputData[data_mem_idx * layerSize + dimIdx];
		}else if (initSmooth){
		    // If there is no data at the begining: use the first time step
		    // If there is no data at the end: use the current time step
		    if (data_time_idx < 0)
			tmp += (inputData[BlockInIdx * layerSize + dimIdx] * filterCoeff);
		    else
			tmp += (lastValidValue * filterCoeff);
		}else{
		    // do nothing
		}
	    }
	    t.get<0>() = tmp;
	}
    };
    
    
    struct causalFilteringBackward_none_selective
    {
	int        filterLength;
	int        filterShareAcrossDim;
	
	int        layerSize;
	int        maxLength;
	int        parallel;
	int        noncausal;
	
	real_t     *inputErrors;
	real_t     *filterCoeffs;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize;  // dimension index
	    int timeIdx    = outputIdx / layerSize;  // time index (regardless of parallel)
	    
	    int BlockIdx   = timeIdx / parallel;     // time index (considering parallel mode)
	    int BlockInIdx = timeIdx % parallel;     // index within a parallel block

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer

	    if (noncausal)
		filter_idx_shift = filterLength / 2;

	    for (int idx = 0 ; idx < filterLength; idx++){

		// get the filter coefficient for one step
		// a_0 + a_1 z^-1 + ... + a_N z^-N
		// [a_0, a_1, ..., a_N]
		if (filterShareAcrossDim)
		    filterCoeff = filterCoeffs[idx];
		else
		    filterCoeff = filterCoeffs[dimIdx * filterLength + idx];

		data_time_idx = BlockIdx + idx - filter_idx_shift;
		data_mem_idx = data_time_idx * parallel + BlockInIdx;

		if (data_mem_idx < maxLength && patTypes[data_mem_idx] != PATTYPE_NONE &&
		    data_time_idx >= 0){
		    tmp += inputErrors[data_mem_idx * layerSize + dimIdx] * filterCoeff;
		}else{
		    // Just ignore the gradients for the two-ends;
		}
	    }
	    t.get<0>() = tmp;
	    
	}
    };


    // Use weighted sum of filters
    struct causalFilteringForward_selective
    {
	int        filterLength;
	int        filterShareAcrossDim;
	
	int        outputLayerSize;
	int        inputLayerSize;
	int        filterNum;
	int        parallel;
	int        initSmooth;

	int        maxLength;
	int        noncausal;
	
	real_t     *inputData;
	real_t     *filterCoeffs;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % outputLayerSize;  // dimension index
	    int timeIdx    = outputIdx / outputLayerSize;  // time index (regardless of parallel)
	    
	    int BlockIdx   = timeIdx / parallel;     // time index (considering parallel mode)
	    int BlockInIdx = timeIdx % parallel;     // index within a parallel block

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff  = 0.0;
	    real_t filterWeight = 0.0;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer
	    
	    if (noncausal)
		filter_idx_shift = filterLength / 2;
	    
	    for (int idx = 0 ; idx < filterLength; idx++){

		// The input vector looks like:
		// [data_dim1, data_dim2, ..., data_dim_N, filter_w1, filter_w2, ...filter_wM]
		// M + N = inputLayerSize
		// N = outputLayerSize
		// M = filterNum
		
		filterCoeff = 0.0;
		
		// get weighted sum of filter weights
		for (int filterIdx = 0 ; filterIdx < filterNum; filterIdx++){

		    // weight of current time step
		    filterWeight = inputData[timeIdx * inputLayerSize +
					     inputLayerSize - filterNum + filterIdx];

		    // weighted sum of filter coeffs
		    if (filterShareAcrossDim)
			filterCoeff += (filterCoeffs[filterIdx * filterLength + idx] * filterWeight);
		    else
			filterCoeff += (filterCoeffs[(filterIdx * outputLayerSize + dimIdx) *
						     filterLength + idx] * filterWeight);
		}
		
		data_time_idx = BlockIdx - idx + filter_idx_shift;
		data_mem_idx = data_time_idx * parallel + BlockInIdx;
		
		if (data_time_idx >= 0 && data_mem_idx < maxLength &&
		    patTypes[data_mem_idx] != PATTYPE_NONE){
		    
		    // when this time step is [0, max_length) and valid
		    tmp += inputData[data_mem_idx * inputLayerSize + dimIdx] * filterCoeff;
		    
		}else if (initSmooth){
		    // If there is no data at the begining: use the first time step
		    // If there is no data at the end: use the current time step
		    if (data_time_idx < 0)
			tmp += (inputData[BlockInIdx * inputLayerSize + dimIdx] * filterCoeff);
		    else
			tmp += (inputData[timeIdx * inputLayerSize + dimIdx] * filterCoeff);
		}else{
		    // do nothing
		}
	    }
	    t.get<0>() = tmp;
	    
	}
    };
    
    
    struct causalFilteringBackward_selective
    {
	int        filterLength;
	int        filterShareAcrossDim;

	int        outputLayerSize;
	int        inputLayerSize;
	int        filterNum;
	int        noncausal;
	int        maxLength;
	int        parallel;
	
	real_t     *inputData;
	real_t     *inputErrors;
	real_t     *filterCoeffs;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % inputLayerSize;  // dimension index
	    int timeIdx    = outputIdx / inputLayerSize;  // time index (regardless of parallel)
	    
	    int BlockIdx   = timeIdx / parallel;     // time index (considering parallel mode)
	    int BlockInIdx = timeIdx % parallel;     // index within a parallel block


	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff  = 0.0;
	    real_t filterWeight = 0.0;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer

	    if (noncausal)
		filter_idx_shift = filterLength / 2;

	    
	    if (dimIdx < (inputLayerSize - filterNum)){
		
		// gradients w.r.t input signal
		for (int idx = 0 ; idx < filterLength; idx++){

		    data_time_idx = BlockIdx + idx - filter_idx_shift;
		    data_mem_idx = data_time_idx * parallel + BlockInIdx;
		
		    // if the output time step is valid
		    if (data_mem_idx < maxLength && patTypes[data_mem_idx] != PATTYPE_NONE &&
			data_time_idx >= 0){

			filterCoeff = 0.0;
			
			for (int filter_idx = 0 ; filter_idx < filterNum; filter_idx++){

			    // weight of that (output) time step 
			    filterWeight = inputData[data_mem_idx * inputLayerSize +
						     inputLayerSize - filterNum + filter_idx];
			    
			    if (filterShareAcrossDim)
				filterCoeff += (filterCoeffs[filter_idx * filterLength + idx] *
						filterWeight);
			    else
				filterCoeff += (filterCoeffs[(filter_idx*outputLayerSize+dimIdx) *
							     filterLength + idx] *
						filterWeight);
			}
		
			// sum gradient
			tmp += (inputErrors[data_mem_idx * outputLayerSize + dimIdx] * filterCoeff);
		    }
		}
		t.get<0>() = tmp;
		
	    }else{

		// gradients w.r.t filter weights
		int filter_idx = dimIdx - outputLayerSize;

		for (int idx = 0 ; idx < filterLength; idx++){

		    data_time_idx = BlockIdx + idx - filter_idx_shift;
		    data_mem_idx = data_time_idx * parallel + BlockInIdx;

		    if (data_mem_idx >= maxLength || patTypes[data_mem_idx] == PATTYPE_NONE ||
			data_time_idx < 0)
			continue;
			    
		    if (filterShareAcrossDim){
			filterCoeff = filterCoeffs[filter_idx * filterLength + idx];
			for (int featDimIdx = 0 ; featDimIdx < outputLayerSize; featDimIdx ++){
			    tmp += (inputData[data_mem_idx * inputLayerSize + featDimIdx]
				    * filterCoeff
				    * inputErrors[timeIdx * outputLayerSize + featDimIdx]);
			}
			
		    }else{
			for (int featDimIdx = 0 ; featDimIdx < outputLayerSize; featDimIdx ++){
			    filterCoeff = filterCoeffs[(filter_idx * outputLayerSize + featDimIdx) *
						       filterLength + idx];
			    tmp += (inputData[data_mem_idx * inputLayerSize + featDimIdx]
				    * filterCoeff
				    * inputErrors[timeIdx * outputLayerSize + featDimIdx]);
			}
		    }
		}
		t.get<0>() = tmp;
	    }
	    
	}
    };


    struct time_variant_filtering_forward
    {
	int        filterLength;            
	int        layerSize_pre;
	int        layerSize_cur;
	int        parallel;
	int        dilation_size;
	int        initSmooth;
	int        noncausal;
	int        maxLength;
	
	real_t     *inputData;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize_cur;  
	    int timeIdx    = outputIdx / layerSize_cur;  
	    
	    int BlockIdx   = timeIdx / parallel;     
	    int BlockInIdx = timeIdx % parallel;     

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff = 1.0;  
	    real_t lastValidValue = 0.0;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer

	    // for noncausal filter, shift the time index
	    if (noncausal)
		filter_idx_shift = filterLength / 2;
	    
	    for (int idx = 0 ; idx < filterLength; idx++){
		    
		// get the filter coefficient for one step
		// a_0 + a_1 z^-1 + ... + a_N z^-N
		// previous_layer.outputs() one frame [data_1, data_2, data_M, a_0, a_1, ..., a_N]
		filterCoeff =
		    inputData[timeIdx * layerSize_pre + layerSize_cur + idx];

		// time index (of parallel block)
		data_time_idx = BlockIdx - (idx - filter_idx_shift) * dilation_size;
		// time index (abosolute time step in memory buffer)
		data_mem_idx = data_time_idx * parallel + BlockInIdx;
		
		if (data_time_idx >= 0 && data_mem_idx < maxLength &&
		    patTypes[data_mem_idx] != PATTYPE_NONE){
		    // when this time step is [0, max_length) and valid
		    tmp += inputData[data_mem_idx * layerSize_pre + dimIdx] * filterCoeff;
		    lastValidValue = inputData[data_mem_idx * layerSize_pre + dimIdx];
		    
		}else if (initSmooth){
		    // If there is no data at the begining: use the first time step
		    // If there is no data at the end: use the current time step
		    if (data_time_idx < 0)
			tmp += (inputData[BlockInIdx * layerSize_pre + dimIdx] * filterCoeff);
		    else
			tmp += (lastValidValue * filterCoeff);
		}else{
		    // do nothing
		}
	    }
	    t.get<0>() = tmp;
	}
    };


    struct time_invariant_filtering_forward
    {
	// difference from time_variant_filtering_forward
	// filterCoeffients are read from the m_filterCoeffLayer_ptr, not
	// this->precedingLayer().output
	// and m_filterCoeffLayer_ptr[0:filter_length] is read for every time step
	int        filterLength;            
	int        layerSize_pre;
	int        layerSize_cur;
	int        parallel;
	int        dilation_size;
	int        initSmooth;
	int        noncausal;
	int        maxLength;

	real_t     *filterCoefs;
	real_t     *inputData;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize_cur;  
	    int timeIdx    = outputIdx / layerSize_cur;  
	    
	    int BlockIdx   = timeIdx / parallel;     
	    int BlockInIdx = timeIdx % parallel;     

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff = 1.0;  
	    real_t lastValidValue = 0.0;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer

	    // for noncausal filter, shift the time index
	    if (noncausal)
		filter_idx_shift = filterLength / 2;
	    
	    for (int idx = 0 ; idx < filterLength; idx++){
		    
		// get the filter coefficient for one step
		// a_0 + a_1 z^-1 + ... + a_N z^-N
		filterCoeff = filterCoefs[idx];

		// time index (of parallel block)
		data_time_idx = BlockIdx - (idx - filter_idx_shift) * dilation_size;
		// time index (abosolute time step in memory buffer)
		data_mem_idx = data_time_idx * parallel + BlockInIdx;
		
		if (data_time_idx >= 0 && data_mem_idx < maxLength &&
		    patTypes[data_mem_idx] != PATTYPE_NONE){
		    // when this time step is [0, max_length) and valid
		    tmp += inputData[data_mem_idx * layerSize_pre + dimIdx] * filterCoeff;
		    lastValidValue = inputData[data_mem_idx * layerSize_pre + dimIdx];
		    
		}else if (initSmooth){
		    // If there is no data at the begining: use the first time step
		    // If there is no data at the end: use the current time step
		    if (data_time_idx < 0)
			tmp += (inputData[BlockInIdx * layerSize_pre + dimIdx]*filterCoeff);
		    else
			tmp += (lastValidValue * filterCoeff);
		}else{
		    // do nothing
		}
	    }
	    t.get<0>() = tmp;
	}
    };


    
    struct time_variant_filtering_backward
    {
	int        filterLength;
	
	int        layerSize_pre;
	int        layerSize_cur;
	int        dilation_size;
	
	int        maxLength;
	int        parallel;
	int        noncausal;

	real_t     *inputData;
	real_t     *inputErrors;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize_pre;
	    int timeIdx    = outputIdx / layerSize_pre;
	    
	    int BlockIdx   = timeIdx / parallel;
	    int BlockInIdx = timeIdx % parallel;

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer
	    
	    if (noncausal)
		filter_idx_shift = filterLength / 2;

	    if (dimIdx < layerSize_cur){
		// gradient w.r.t input signal
		for (int idx = 0 ; idx < filterLength; idx++){
		    
		    filterCoeff = inputData[timeIdx * layerSize_pre + layerSize_cur + idx];
		    

		    data_time_idx = BlockIdx + (idx - filter_idx_shift) * dilation_size;
		    data_mem_idx = data_time_idx * parallel + BlockInIdx;
		    
		    if (data_mem_idx < maxLength && patTypes[data_mem_idx] != PATTYPE_NONE &&
			data_time_idx >= 0){
			tmp += inputErrors[data_mem_idx * layerSize_cur + dimIdx] * filterCoeff;
		    }else{
			// Just ignore the gradients for the two-ends;
		    }
		}
		t.get<0>() = tmp;
		
	    }else{
		// gradient w.r.t filter coefficients
		
		int filter_order = dimIdx - layerSize_cur;
		data_time_idx = BlockIdx + (filter_idx_shift - filter_order) * dilation_size;
		data_mem_idx = data_time_idx * parallel + BlockInIdx;


		if (data_time_idx >= 0 && data_mem_idx < maxLength &&
		    patTypes[data_mem_idx] != PATTYPE_NONE){

		    for (int dim_iter = 0; dim_iter < layerSize_cur; dim_iter++){
			tmp += inputErrors[timeIdx * layerSize_cur + dim_iter] *
			    inputData[data_mem_idx * layerSize_pre + dim_iter];
		    }
		    t.get<0>() = tmp;
		}else{
		    t.get<0>() = 0;
		}

	    }
	}
    };

    struct time_invariant_filtering_backward_data
    {
	int        filterLength;
	int        layerSize;
	int        dilation_size;
	int        maxLength;
	int        parallel;
	int        noncausal;

	real_t     *filterCoefs;
	real_t     *inputData;
	real_t     *inputErrors;
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize;
	    int timeIdx    = outputIdx / layerSize;
	    
	    int BlockIdx   = timeIdx / parallel;
	    int BlockInIdx = timeIdx % parallel;

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp = 0.0;
	    real_t filterCoeff;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer
	    
	    if (noncausal)
		filter_idx_shift = filterLength / 2;

	    // gradient w.r.t input signal
	    for (int idx = 0 ; idx < filterLength; idx++){
		    
		filterCoeff = filterCoefs[idx];
		    
		data_time_idx = BlockIdx + (idx - filter_idx_shift) * dilation_size;
		data_mem_idx = data_time_idx * parallel + BlockInIdx;
		    
		if (data_mem_idx < maxLength
		    && patTypes[data_mem_idx] != PATTYPE_NONE
		    && data_time_idx >= 0){
		    tmp += inputErrors[data_mem_idx * layerSize + dimIdx] * filterCoeff;
		}else{
		    // Just ignore the gradients for the two-ends;
		}
	    }
	    t.get<0>() = tmp;
	}
    };


    struct time_invariant_filtering_backward_coef
    {
	int        featureDim;
	int        dilation_size;
	int        maxLength;
	int        parallel;
	int        noncausal;
	int        filterLength;
	
	real_t     *inputData;
	real_t     *inputErrors;
	const char *patTypes;   

	// From 1 : filter_length
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    
	    int filterCoefIdx  = t.get<1>();
	    
	    // accumulate and update
	    real_t tmp = 0.0;
	    
	    int    filter_idx_shift = 0;
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer
	    
	    if (noncausal)
		filter_idx_shift = filterLength / 2;
	    
	    for (int dimIdx = 0; dimIdx < featureDim; dimIdx++){
		for (int timeIdx = 0 ; timeIdx < maxLength; timeIdx++){

		    // block index in parallel mode
		    data_time_idx = (timeIdx / parallel)
			- (filterCoefIdx - filter_idx_shift) * dilation_size;
		    data_mem_idx = data_time_idx * parallel + (timeIdx % parallel);

		    if (data_time_idx >= 0
			&& data_mem_idx < maxLength
			&& patTypes[data_mem_idx] != PATTYPE_NONE
			&& patTypes[timeIdx] != PATTYPE_NONE){
			
			tmp += (inputErrors[timeIdx * featureDim + dimIdx]
				* inputData[data_mem_idx * featureDim + dimIdx]);
		    }
		}
	    }
	    t.get<0>() = tmp;
	}
    };
    

    struct time_domain_reverb_get_decay_coef_forward
    {
	int        layerSize_pre;
	int        layerSize_cur;
	real_t     decayScale;
	real_t     decayShift;	
	real_t     *inputData;
	const char *patTypes;
	
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize_cur;  
	    int timeIdx    = outputIdx / layerSize_cur;  
	    
	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;		
	    }else{
		t.get<0>() = exp(inputData[timeIdx * layerSize_pre + layerSize_cur + dimIdx] * decayScale
				 + decayShift);
	    }
	}
    };

    struct time_domain_reverb_norm_statistics_decay_coef_forward
    {

	bool       flag_norm;
	int        layerSize_cur;
	int        filterLength;
	real_t     *statisBuffer;
	real_t     *noise;
	const char *patTypes;   

	// From 1 : T 
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize_cur;  
	    int timeIdx    = outputIdx / layerSize_cur;  

	    real_t tmp_coef_sum = 1.0;
	    real_t tmp_coef_t_sum = 0.0;
		
	    if (patTypes[timeIdx] == PATTYPE_NONE || flag_norm == false){
		
	    }else{	  

		int idx = 0;
		real_t filterCoeff = 0.0;
		
		// online average
		for (idx = 0 ; idx < filterLength; idx++){
		    filterCoeff = exp(-1.0 * idx * t.get<0>());
		    if (filterCoeff < FILTERING_LAYER_REVERB_IR_THRESHOD)
			break;
		    if (noise)
			filterCoeff = noise[idx * layerSize_cur + dimIdx] * filterCoeff;
		    tmp_coef_sum = tmp_coef_sum + (filterCoeff - tmp_coef_sum) / (idx+1);
		    tmp_coef_t_sum = tmp_coef_t_sum + (filterCoeff * idx - tmp_coef_sum) / (idx+1);
		}
		// average -> sum
		tmp_coef_sum = tmp_coef_sum * idx;
		tmp_coef_t_sum = tmp_coef_t_sum * idx;
	    }
	    
	    statisBuffer[timeIdx * layerSize_cur * 2 + dimIdx] = tmp_coef_sum;
	    statisBuffer[timeIdx * layerSize_cur * 2 + dimIdx + layerSize_cur] = tmp_coef_t_sum;
	}
    };
        
    struct time_domain_reverb_forward
    {
	int        filterLength;            
	int        layerSize_pre;
	int        layerSize_cur;
	int        parallel;
	int        dilation_size;
	int        initSmooth;
	int        noncausal;
	int        maxLength;

	real_t     *decayCoef;
	real_t     *decayStat;
	real_t     *decayGrad;
	real_t     *inputData;
	real_t     *noise;
	
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize_cur;  
	    int timeIdx    = outputIdx / layerSize_cur;  
	    
	    int BlockIdx   = timeIdx / parallel;     
	    int BlockInIdx = timeIdx % parallel;     

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		if (decayGrad)
		    decayGrad[t.get<1>()] = 0.0;
	    }else{	  

		// accumulate and update
		real_t tmp_single_step_value = 0;
		real_t tmp_conv_value = 0.0;
		real_t tmp_grad_value = 0.0;
		
		real_t filterCoeff = 1.0;
		real_t lastValidValue = 0.0;
		
		int    data_time_idx;  // the relative time step index
		int    data_mem_idx;   // the absolute time step in memory buffer

		// convolution
		for (int idx = 0 ; idx < filterLength; idx++){
		        
		    // time index (of parallel block)
		    data_time_idx = BlockIdx - idx * dilation_size;
		    // time index (abosolute time step in memory buffer)
		    data_mem_idx = data_time_idx * parallel + BlockInIdx;

		    filterCoeff = exp(-1.0 * idx * decayCoef[outputIdx]);

		    if (filterCoeff < FILTERING_LAYER_REVERB_IR_THRESHOD)
			break;
		    
		    if (noise)
			filterCoeff = noise[idx * layerSize_cur + dimIdx] * filterCoeff;

		    // norm
		    filterCoeff = filterCoeff / decayStat[timeIdx * layerSize_cur * 2 + dimIdx];
		    
		    if (data_time_idx >= 0 && data_mem_idx < maxLength &&
			patTypes[data_mem_idx] != PATTYPE_NONE){
			// when this time step is [0, max_length) and valid
			tmp_single_step_value = inputData[data_mem_idx * layerSize_pre + dimIdx] * filterCoeff;
			lastValidValue = inputData[data_mem_idx * layerSize_pre + dimIdx];
		    
		    }else if (initSmooth){
			// If there is no data at the begining: use the first time step
			// If there is no data at the end: use the current time step
			if (data_time_idx < 0)
			    tmp_single_step_value =
				inputData[BlockInIdx * layerSize_pre + dimIdx] * filterCoeff;
			else
			    tmp_single_step_value = lastValidValue * filterCoeff;
		    }else{
			tmp_single_step_value = 0.0;
		    }
		    tmp_conv_value += tmp_single_step_value;
		    tmp_grad_value += (tmp_single_step_value * (-idx));

		}
		t.get<0>() = tmp_conv_value;
		decayGrad[t.get<1>()] = tmp_grad_value;
	    }
	}
    };


    struct time_domain_reverb_backward
    {
	int        filterLength;
	int        layerSize_pre;
	int        layerSize_cur;
	int        dilation_size;
	int        maxLength;
	int        parallel;
	real_t     decayScale;

	real_t     *inputData;
	real_t     *outputData;
	real_t     *outputErrors;
	real_t     *decayCoef;
	real_t     *decayStat;
	real_t     *decayGrad;
	real_t     *noise;
	
	const char *patTypes;   

	// From 1 : T (of the previous layer)
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    
	    int outputIdx  = t.get<1>();
	    int dimIdx     = outputIdx % layerSize_pre;
	    int timeIdx    = outputIdx / layerSize_pre;
	    
	    int BlockIdx   = timeIdx / parallel;
	    int BlockInIdx = timeIdx % parallel;

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0;
		return;
	    }		

	    // accumulate and update
	    real_t tmp_grad_value = 0.0;
	    real_t filterCoeff;
	    real_t decayValue;
	    
	    int    data_time_idx;  // the relative time step index
	    int    data_mem_idx;   // the absolute time step in memory buffer
	    
	    if (dimIdx < layerSize_cur){

		decayValue = decayCoef[timeIdx * layerSize_cur + dimIdx];
		
		// gradient w.r.t input signal
		for (int idx = 0 ; idx < filterLength; idx++){
		    
		    filterCoeff = exp(-1.0 * idx * decayValue);
		    
		    if (filterCoeff < FILTERING_LAYER_REVERB_IR_THRESHOD)
			break;
		    
		    if (noise)
			filterCoeff = filterCoeff * noise[idx * layerSize_cur + dimIdx];
		    
		    // norm
		    filterCoeff = filterCoeff / decayStat[timeIdx * layerSize_cur * 2 + dimIdx];

		    data_time_idx = BlockIdx + idx * dilation_size;
		    data_mem_idx = data_time_idx * parallel + BlockInIdx;
		    
		    if (data_mem_idx < maxLength && patTypes[data_mem_idx] != PATTYPE_NONE &&
			data_time_idx >= 0){
			tmp_grad_value += (outputErrors[data_mem_idx * layerSize_cur + dimIdx] * filterCoeff);
		    }else{
			// Just ignore the gradients for the two-ends;
		    }
		}
		
		t.get<0>() = tmp_grad_value;
		
	    }else{

		// dimIdx - layerSize_cur is the real dimIdx
		int mem_idx = timeIdx * layerSize_cur + (dimIdx - layerSize_cur);
		int mem_idx2 = timeIdx * layerSize_cur * 2 + (dimIdx - layerSize_cur);
		// gradient w.r.t decay factor
		t.get<0>() = outputErrors[mem_idx] *
		    (decayGrad[mem_idx] +
		     outputData[mem_idx] * decayStat[mem_idx2 + layerSize_cur] / decayStat[mem_idx2]) *
		    decayCoef[mem_idx] * decayScale;
	    }
	}
    };
    
    
}
}

namespace layers {
    template <typename TDevice>
    FilteringLayer<TDevice>::FilteringLayer(const helpers::JsonValue &layerChild,
					    const helpers::JsonValue &weightsSection,
					    Layer<TDevice>           &precedingLayer,
					    int                       maxSeqLength,
					    int                       layerID)
	: TrainableLayer<TDevice>(layerChild, weightsSection, 0, 0,
				  precedingLayer, maxSeqLength, layerID)
    {
	// load the options from network.jsn
	this->__loadOpts(layerChild);
	
	// display the options
	this->__showOpts();

	// allocation memory
	this->__allocateLocalMem();
	
	if (this->getResolution() != this->precedingLayer().getResolution())
	    throw std::runtime_error("Error: resolution != previous layer resolution");
	
    }

    template <typename TDevice>
    FilteringLayer<TDevice>::~FilteringLayer()
    {
    }

    template <typename TDevice>
    void FilteringLayer<TDevice>::__loadOpts(const helpers::JsonValue &layerChild)
    {
	// load options
	m_filter_across_dim = ((layerChild->HasMember("shareAcrossDim")) ? 
			       ((*layerChild)["shareAcrossDim"].GetInt()) : 1);
	
	m_filter_coeffs_str = ((layerChild->HasMember("filterCoeffs")) ? 
			       ((*layerChild)["filterCoeffs"].GetString()) : "");
	
	m_filter_coef_layer = ((layerChild->HasMember("filterCoeffsLayer")) ? 
				 ((*layerChild)["filterCoeffsLayer"].GetString()) : "");
	
	m_filter_length = ((layerChild->HasMember("filterLength")) ? 
			       ((*layerChild)["filterLength"].GetInt()) : 0);
	
	
	m_filter_initial_keep = ((layerChild->HasMember("initialCondSmooth")) ? 
			       ((*layerChild)["initialCondSmooth"].GetInt()) : 0);
	
	m_filter_noncausal = ((layerChild->HasMember("noncausal")) ? 
			       ((*layerChild)["noncausal"].GetInt()) : 0);

	m_filter_mode = ((layerChild->HasMember("filter_mode")) ? 
			 ((*layerChild)["filter_mode"].GetInt()) :
			 FILTERING_LAYER_MODE_NONE_SELECTIVE);

	m_dilation_size = ((layerChild->HasMember("dilation_size")) ? 
			   ((*layerChild)["dilation_size"].GetInt()) : 1);

	m_dilation_size = ((layerChild->HasMember("dilation_size")) ? 
			   ((*layerChild)["dilation_size"].GetInt()) : 1);

	m_reverb_IR_noise = ((layerChild->HasMember("reverb_noise")) ? 
			     ((*layerChild)["reverb_noise"].GetInt()) : 1);
	
	m_reverb_decayScale = ((layerChild->HasMember("reverb_decay_scale")) ? 
			       ((*layerChild)["reverb_decay_scale"].GetDouble()) : 1.0);
	
	m_reverb_decayShift = ((layerChild->HasMember("reverb_decay_shift")) ? 
			       ((*layerChild)["reverb_decay_shift"].GetDouble()) : 0.0);

	m_reverb_normalize = ((layerChild->HasMember("reverb_DC_gain_0dB")) ? 
			      ((*layerChild)["reverb_DC_gain_0dB"].GetInt()) : 0);
	
	if (m_filter_mode == FILTERING_LAYER_MODE_NONE_SELECTIVE ||
	    m_filter_mode == FILTERING_LAYER_MODE_SELECTIVE){

	    // parse the filter coefficients
	    if (m_filter_coeffs_str.size() == 0)
		throw std::runtime_error("\nError: filterCoeffs is not specified");

	    if (this->size() == this->precedingLayer().size()){
		m_filter_mode = FILTERING_LAYER_MODE_NONE_SELECTIVE;
		// only 1 group of filter, for all dimensions
		m_filter_num = 1;
	    }else{
		// multiple groups of filters
		m_filter_num = this->precedingLayer().size() - this->size();
		m_filter_mode = FILTERING_LAYER_MODE_SELECTIVE;
	    }
	    
	    m_filter_coeffs.clear();
	    misFuncs::ParseFloatOpt(m_filter_coeffs_str, m_filter_coeffs_H);
	    m_filter_coeffs = m_filter_coeffs_H;
	    
	    // check, when shareAcrossDim is False,
	    // #coefficients should be N * feature dimension
	    if (m_filter_across_dim == 0){
		if (m_filter_coeffs_H.size() % this->size() != 0){
		    printf("\n\t %d filter coefficients for %d dimensions,",
			   this->size(),
			   (int)m_filter_coeffs_H.size());
		    throw std::runtime_error("Error: filterCoeffs invalid");
		}
	    }
	    
	    int tmp_filter_length = 0;
	    // if m_filter_length is not specified, infer it
	    if (m_filter_across_dim == 0)
		tmp_filter_length = (m_filter_coeffs_H.size() / this->size() /
				     m_filter_num);
	    else
		tmp_filter_length = m_filter_coeffs_H.size() / m_filter_num;

	
	    if (m_filter_length == 0){
		m_filter_length = tmp_filter_length;
		
	    }else if (m_filter_length != tmp_filter_length){
		throw std::runtime_error("Error: filter length mismatch");
	    }else{
		// nothing, the filter_length has been correctly configured
	    }

	    m_reverb_IR_noise = 0;
	    
	}else if (m_filter_mode == FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS){

	    // initialize it
	    if (m_filter_coef_layer.size()){
		// these two terms will be loaded in linkTargetLayer
		m_filter_coef_layer_ptr = NULL;
		m_filter_length = 0;
		m_filter_mode = FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS;
		
	    }else{
		m_filter_coef_layer_ptr = NULL;
		if (m_filter_across_dim){
		    if (m_filter_length == 0)
			m_filter_length = this->precedingLayer().size() - this->size();
		
		    if (m_filter_length <= 0 ||
			this->precedingLayer().size() != (m_filter_length + this->size()))
			throw std::runtime_error("Error: filter lengh mis-configured");
		
		    m_filter_mode = FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS;
		
		}else{
		    throw std::runtime_error("Error: shareAcrossDim=0 is not supported");
		}
	    }
	    m_reverb_IR_noise = 0;
	    
	}else if (m_filter_mode == FILTERING_LAYER_REVERB){

	    //if (m_reverb_IR_noise)
	    //m_reverb_IR_noise_vec.resize(this->outputs().size(), 0.0);
	    
	    //m_reverb_grad_buf.resize(this->outputs().size(), 0.0);
	    
	    if (this->precedingLayer().size() != (this->size() * 2))
		throw std::runtime_error("Error: layer size != preceding layer size * 2");

	    m_filter_across_dim = 0;
	    
	    if (m_filter_length > this->outputs().size()){
		m_filter_length = this->outputs().size();
		printf("\n\tFilter length is too long and is set to %d", m_filter_length);
	    }
	}else{
	    throw std::runtime_error("Error: unknown filter mode");
	}

    }
    
    template <typename TDevice>
    void FilteringLayer<TDevice>::__showOpts()
    {
	// show options
	// print information
	if (m_filter_mode == FILTERING_LAYER_MODE_NONE_SELECTIVE){
	    printf("\n\tfixed filter, ");
	    
	}else if (m_filter_mode == FILTERING_LAYER_MODE_SELECTIVE){
	    printf("\n\tsoft-weighted %d filters, ", m_filter_num);
	    
	}else if (m_filter_mode == FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS){
	    if (m_filter_coef_layer.size()){
		printf("\n\ttime-invariant filter (coef %s)", m_filter_coef_layer.c_str());
	    }else{
		printf("\n\ttime-variant filters with filter order = %d", m_filter_length);
	    }
	}else if (m_filter_mode == FILTERING_LAYER_REVERB){
	    printf(" trainable decay filter %d of length ", m_filter_length);
	    if (m_reverb_IR_noise)
		printf("\n\twith noise multiplied decay function");
	    if (m_reverb_normalize)
		printf("\n\tDC gain normalized to 0dB");
	}else{
	    throw std::runtime_error("Error: unknown filtering mode");
	}
	
	if (m_filter_across_dim)
	    printf("\n\tone filter (length %d) across feature dimension,",
		   m_filter_length);
	else
	    printf("\n\tone filter (length %d) for each feature dimension,",
		   m_filter_length);

	if (m_filter_noncausal)
	    printf(" noncausal,");
	else
	    printf(" causal,");

	if (m_filter_initial_keep)
	    printf("\n\tboundary smoothed,");
	else
	    printf("\n\tboundary not smooth,");

	if (m_dilation_size > 1)
	    printf("\n\tDilation size %d", m_dilation_size);
    }

    template <typename TDevice>
    void FilteringLayer<TDevice>::__allocateLocalMem()
    {
	if (m_filter_mode == FILTERING_LAYER_REVERB){
	    
	    if (m_reverb_IR_noise)
		m_reverb_IR_noise_vec.resize(this->outputs().size(), 0.0);
	    
	    m_reverb_norm_buf_vec.resize(this->outputs().size() * 2, 0.0);	
	    m_reverb_grad_buf.resize(this->outputs().size(), 0.0);
	    m_reverb_decay_coef_vec.resize(this->outputs().size(), 0.0);
	}
    }
    
    template <typename TDevice>
    void FilteringLayer<TDevice>::__clearLocalMem()
    {
	if (m_filter_mode == FILTERING_LAYER_REVERB){
	    
	    if (m_reverb_IR_noise){
		m_reverb_IR_noise_vec.clear();
		m_reverb_IR_noise_vec.shrink_to_fit();
	    }
	    m_reverb_norm_buf_vec.clear();
	    m_reverb_norm_buf_vec.shrink_to_fit();
	    m_reverb_grad_buf.clear();
	    m_reverb_grad_buf.shrink_to_fit();
	    m_reverb_decay_coef_vec.clear();
	    m_reverb_decay_coef_vec.shrink_to_fit();
	}
    }    
    template <typename TDevice>
    const std::string& FilteringLayer<TDevice>::type() const
    {
        static std::string s;
        if (s.empty()) s = "filtering";
        return s;
    }

    template <typename TDevice>
    void FilteringLayer<TDevice>::computeForwardPass(const int nnState)
    {
	int timeLength = this->curMaxSeqLength() * this->parallelSequences();
	
	if (m_filter_mode == FILTERING_LAYER_MODE_NONE_SELECTIVE){
	    // one group of filters
	    internal::causalFilteringForward_none_selective fn1;
	    fn1.filterLength         = this->m_filter_length;
	    fn1.layerSize            = this->size();
	    fn1.parallel             = this->parallelSequences();
	    fn1.filterShareAcrossDim = this->m_filter_across_dim;
	    fn1.initSmooth           = this->m_filter_initial_keep;
	    fn1.noncausal            = this->m_filter_noncausal;
	    fn1.maxLength            = timeLength;

	    fn1.filterCoeffs  = helpers::getRawPointer(this->m_filter_coeffs);
	    fn1.inputData     = helpers::getRawPointer(this->precedingLayer().outputs());
	    fn1.patTypes      = helpers::getRawPointer(this->patTypes());

	    int n = timeLength * this->size();
	    thrust::for_each(
               thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin(),
				     thrust::counting_iterator<int>(0))),
	       thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin()           + n,
				     thrust::counting_iterator<int>(0) + n)),
	       fn1);
	    
	}else if (m_filter_mode == FILTERING_LAYER_MODE_SELECTIVE){
	    // weighted sum of filters
	    internal::causalFilteringForward_selective fn1;
	    fn1.filterLength    = this->m_filter_length;
	    fn1.filterShareAcrossDim = this->m_filter_across_dim;
	    
	    fn1.outputLayerSize = this->size();
	    fn1.inputLayerSize  = this->precedingLayer().size();
	    fn1.filterNum       = m_filter_num;
	    fn1.parallel        = this->parallelSequences();
	    fn1.maxLength       = timeLength;
	    
	    fn1.initSmooth      = this->m_filter_initial_keep;	    
	    fn1.noncausal       = this->m_filter_noncausal;
	    
	    fn1.filterCoeffs  = helpers::getRawPointer(this->m_filter_coeffs);
	    fn1.inputData     = helpers::getRawPointer(this->precedingLayer().outputs());
	    fn1.patTypes      = helpers::getRawPointer(this->patTypes());
	    
	    int n = timeLength * this->size();
	    thrust::for_each(
               thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin(),
				     thrust::counting_iterator<int>(0))),
	       thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin()           + n,
				     thrust::counting_iterator<int>(0) + n)),
	       fn1);
	    
	}else if (m_filter_mode == FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS){
	    
	    int n = timeLength * this->size();
	    
	    // predicted filter coefficients
	    if (m_filter_coef_layer_ptr){
		internal::time_invariant_filtering_forward fn1;
		fn1.filterLength         = this->m_filter_length;
		fn1.layerSize_pre        = this->precedingLayer().size();
		fn1.layerSize_cur        = this->size();
		fn1.parallel             = this->parallelSequences();
		
		fn1.dilation_size        = this->m_dilation_size;	    
		fn1.initSmooth           = this->m_filter_initial_keep;
		fn1.noncausal            = this->m_filter_noncausal;
		fn1.maxLength            = timeLength;

		fn1.filterCoefs = helpers::getRawPointer(m_filter_coef_layer_ptr->outputs());
		fn1.inputData   = helpers::getRawPointer(this->precedingLayer().outputs());
		fn1.patTypes    = helpers::getRawPointer(this->patTypes());

	
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin()           + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn1);
		
	    }else{
		internal::time_variant_filtering_forward fn1;
		fn1.filterLength         = this->m_filter_length;
		fn1.layerSize_pre        = this->precedingLayer().size();
		fn1.layerSize_cur        = this->size();
		fn1.parallel             = this->parallelSequences();
		
		fn1.dilation_size        = this->m_dilation_size;	    
		fn1.initSmooth           = this->m_filter_initial_keep;
		fn1.noncausal            = this->m_filter_noncausal;
		fn1.maxLength            = timeLength;
	    
		fn1.inputData = helpers::getRawPointer(this->precedingLayer().outputs());
		fn1.patTypes  = helpers::getRawPointer(this->patTypes());

	
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin()           + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn1);
	    }
	    
	}else if (m_filter_mode == FILTERING_LAYER_REVERB){

	    // produce noise
	    if (m_reverb_IR_noise){
		thrust::counting_iterator<unsigned int> index_sequence_begin(0);
		thrust::transform(
			index_sequence_begin,
			index_sequence_begin + timeLength * this->size(),
			m_reverb_IR_noise_vec.begin(),
			internal::genNoise(-1.0, 1.0,
					   (int)(misFuncs::GetRandomNumber()*10000.0)));
	    }

	    int n = timeLength * this->size();
	    
	    // convert raw coef to decay factor
	    {
		internal::time_domain_reverb_get_decay_coef_forward fn1;
		fn1.layerSize_pre        = this->precedingLayer().size();
		fn1.layerSize_cur        = this->size();
		fn1.decayScale           = this->m_reverb_decayScale;
		fn1.decayShift           = this->m_reverb_decayShift;
		fn1.inputData   = helpers::getRawPointer(this->precedingLayer().outputs());
		fn1.patTypes    = helpers::getRawPointer(this->patTypes());		
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(m_reverb_decay_coef_vec.begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(m_reverb_decay_coef_vec.begin()   + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn1);
	    }

	    // get the statistics for normalization
	    {
		internal::time_domain_reverb_norm_statistics_decay_coef_forward fn2;
		fn2.flag_norm      = (m_reverb_normalize > 0);
		fn2.layerSize_cur  = this->size();
		fn2.filterLength   = this->m_filter_length;
		fn2.statisBuffer   = helpers::getRawPointer(m_reverb_norm_buf_vec);
		fn2.patTypes       = helpers::getRawPointer(this->patTypes());
		if (m_reverb_IR_noise)
		    fn2.noise = helpers::getRawPointer(this->m_reverb_IR_noise_vec);
		else
		    fn2.noise = NULL;
		
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(m_reverb_decay_coef_vec.begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(m_reverb_decay_coef_vec.begin()   + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn2);
	    }

	    {
		internal::time_domain_reverb_forward fn3;
		fn3.filterLength         = this->m_filter_length;
		fn3.layerSize_pre        = this->precedingLayer().size();
		fn3.layerSize_cur        = this->size();
		fn3.parallel             = this->parallelSequences();
		fn3.dilation_size        = this->m_dilation_size;	    
		fn3.initSmooth           = this->m_filter_initial_keep;
		fn3.maxLength            = timeLength;
		
		fn3.inputData = helpers::getRawPointer(this->precedingLayer().outputs());
		fn3.patTypes  = helpers::getRawPointer(this->patTypes());
		fn3.decayGrad = helpers::getRawPointer(this->m_reverb_grad_buf);
		fn3.decayCoef = helpers::getRawPointer(this->m_reverb_decay_coef_vec);
		fn3.decayStat = helpers::getRawPointer(this->m_reverb_norm_buf_vec);
	    
		if (m_reverb_IR_noise)
		    fn3.noise = helpers::getRawPointer(this->m_reverb_IR_noise_vec);
		else
		    fn3.noise = NULL;
	    
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin()           + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn3);
	    }
	    
	}else{
	    throw std::runtime_error("Error: filtering layer unknown filter mode");
	}
    }

    template <typename TDevice>
    void FilteringLayer<TDevice>::computeForwardPass(const int timeStep, const int nnState)
    {
	throw std::runtime_error("Filtering computeForwardPass(timeStep) not implemented");
    }

    template <typename TDevice>
    void FilteringLayer<TDevice>::computeBackwardPass(const int nnState)
    {
	int timeLength = this->curMaxSeqLength() * this->parallelSequences();
	
	if (m_filter_mode == FILTERING_LAYER_MODE_NONE_SELECTIVE){    
	    internal::causalFilteringBackward_none_selective fn1;
	    fn1.filterLength = this->m_filter_length;
	    fn1.filterShareAcrossDim = this->m_filter_across_dim;
	    
	    fn1.layerSize    = this->size();
	    fn1.maxLength    = timeLength;
	    fn1.parallel     = this->parallelSequences();
	    fn1.noncausal    = this->m_filter_noncausal;
		    
	    fn1.filterCoeffs  = helpers::getRawPointer(this->m_filter_coeffs);
	    fn1.inputErrors   = helpers::getRawPointer(this->outputErrors());
	    fn1.patTypes      = helpers::getRawPointer(this->patTypes());
	    
	    int n = timeLength * this->size();
	    thrust::for_each(
              thrust::make_zip_iterator(
		thrust::make_tuple(this->precedingLayer().outputErrors().begin(),
				   thrust::counting_iterator<int>(0))),
	      thrust::make_zip_iterator(
		thrust::make_tuple(this->precedingLayer().outputErrors().begin() + n,
				   thrust::counting_iterator<int>(0) + n)),
	      fn1);

	}else if (m_filter_mode == FILTERING_LAYER_MODE_SELECTIVE){
	    
	    internal::causalFilteringBackward_selective fn1;
	    fn1.filterLength     = this->m_filter_length;
	    fn1.filterShareAcrossDim = this->m_filter_across_dim;
	    
	    fn1.outputLayerSize  = this->size();
	    fn1.inputLayerSize   = this->precedingLayer().size();
	    fn1.filterNum        = this->m_filter_num;
	    fn1.maxLength        = timeLength;
	    fn1.parallel         = this->parallelSequences();
	    fn1.noncausal        = this->m_filter_noncausal;
	    

	    fn1.filterCoeffs     = helpers::getRawPointer(this->m_filter_coeffs);
	    fn1.inputData        = helpers::getRawPointer(this->precedingLayer().outputs());
	    fn1.inputErrors      = helpers::getRawPointer(this->outputErrors());
	    fn1.patTypes         = helpers::getRawPointer(this->patTypes());
	    
	    int n = timeLength * this->precedingLayer().size();
	    thrust::for_each(
              thrust::make_zip_iterator(
		thrust::make_tuple(this->precedingLayer().outputErrors().begin(),
				   thrust::counting_iterator<int>(0))),
	      thrust::make_zip_iterator(
		thrust::make_tuple(this->precedingLayer().outputErrors().begin() + n,
				   thrust::counting_iterator<int>(0) + n)),
	      fn1);
	    
	}else if (m_filter_mode == FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS){

	    if (m_filter_coef_layer_ptr){
		// grad w.r.t the input data
		// grad w.r.t input data and filter coefficients
		{
		internal::time_invariant_filtering_backward_data fn1;
		fn1.filterLength  = this->m_filter_length;	    
		fn1.layerSize     = this->precedingLayer().size();
		fn1.dilation_size = this->m_dilation_size;
		fn1.maxLength     = timeLength;
		fn1.parallel      = this->parallelSequences();
		fn1.noncausal     = this->m_filter_noncausal;

		fn1.filterCoefs = helpers::getRawPointer(m_filter_coef_layer_ptr->outputs());
		fn1.inputData   = helpers::getRawPointer(this->precedingLayer().outputs());
		fn1.inputErrors = helpers::getRawPointer(this->outputErrors());
		fn1.patTypes    = helpers::getRawPointer(this->patTypes());
	    
		int n = timeLength * this->precedingLayer().size();
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(this->precedingLayer().outputErrors().begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(this->precedingLayer().outputErrors().begin() + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn1);
		}
		// grad w.r.t the filter coefficients
		{
		internal::time_invariant_filtering_backward_coef fn2;

		fn2.featureDim    = this->precedingLayer().size();
		fn2.dilation_size = this->m_dilation_size;
		fn2.maxLength     = timeLength;
		fn2.parallel      = this->parallelSequences();
		fn2.noncausal     = this->m_filter_noncausal;
		fn2.filterLength  = this->m_filter_length;

		fn2.inputData   = helpers::getRawPointer(this->precedingLayer().outputs());
		fn2.inputErrors = helpers::getRawPointer(this->outputErrors());
		fn2.patTypes    = helpers::getRawPointer(this->patTypes());
	    
		int n = this->m_filter_length;
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(m_filter_coef_layer_ptr->outputErrors().begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(m_filter_coef_layer_ptr->outputErrors().begin() + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn2);
		    
		}
	    }else{

		// grad w.r.t input data and filter coefficients
		internal::time_variant_filtering_backward fn1;
		fn1.filterLength  = this->m_filter_length;
	    
		fn1.layerSize_cur = this->size();
		fn1.layerSize_pre = this->precedingLayer().size();
		fn1.dilation_size = this->m_dilation_size;
	    
		fn1.maxLength     = timeLength;
		fn1.parallel      = this->parallelSequences();
		fn1.noncausal     = this->m_filter_noncausal;

		fn1.inputData = helpers::getRawPointer(this->precedingLayer().outputs());
		fn1.inputErrors = helpers::getRawPointer(this->outputErrors());
		fn1.patTypes    = helpers::getRawPointer(this->patTypes());
	    
		int n = timeLength * this->precedingLayer().size();
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(this->precedingLayer().outputErrors().begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(this->precedingLayer().outputErrors().begin() + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn1);
	    }
	    
	}else if (m_filter_mode == FILTERING_LAYER_REVERB){

	    {
		internal::time_domain_reverb_backward fn1;
		fn1.filterLength  = this->m_filter_length;
		fn1.layerSize_cur = this->size();
		fn1.layerSize_pre = this->precedingLayer().size();
		fn1.dilation_size = this->m_dilation_size;
		fn1.maxLength     = timeLength;
		fn1.parallel      = this->parallelSequences();
		fn1.decayScale    = this->m_reverb_decayScale;
		
		fn1.inputData     = helpers::getRawPointer(this->precedingLayer().outputs());
		fn1.outputData    = helpers::getRawPointer(this->outputs());
		fn1.outputErrors  = helpers::getRawPointer(this->outputErrors());
		fn1.decayGrad     = helpers::getRawPointer(this->m_reverb_grad_buf);
		fn1.decayCoef     = helpers::getRawPointer(this->m_reverb_decay_coef_vec);
		fn1.decayStat     = helpers::getRawPointer(this->m_reverb_norm_buf_vec);
		fn1.patTypes      = helpers::getRawPointer(this->patTypes());

		if (m_reverb_IR_noise)
		    fn1.noise     = helpers::getRawPointer(this->m_reverb_IR_noise_vec);
		else
		    fn1.noise = NULL;
	    
		int n = timeLength * this->precedingLayer().size();
		thrust::for_each(
                 thrust::make_zip_iterator(
		  thrust::make_tuple(this->precedingLayer().outputErrors().begin(),
				     thrust::counting_iterator<int>(0))),
		 thrust::make_zip_iterator(
		  thrust::make_tuple(this->precedingLayer().outputErrors().begin() + n,
				     thrust::counting_iterator<int>(0) + n)),
		 fn1);
	    }
	    
	}else{
	    throw std::runtime_error("Error: filtering layer Unknown filter mode");
	}
	
    }
    
    template <typename TDevice>
    void FilteringLayer<TDevice>::computeBackwardPass(const int timeStep, const int nnState)
    {
	throw std::runtime_error("Filtering computeBackwardPass(timeStep) not supported");
    }
    
    template <typename TDevice>
    void FilteringLayer<TDevice>::exportLayer(
	const helpers::JsonValue     &layersArray, 
	const helpers::JsonAllocator &allocator) const
    {
	TrainableLayer<TDevice>::exportLayer(layersArray, allocator);
        (*layersArray)[layersArray->Size() - 1].AddMember("shareAcrossDim",
							  m_filter_across_dim,
							  allocator);
	(*layersArray)[layersArray->Size() - 1].AddMember("filterCoeffs",
							  m_filter_coeffs_str.c_str(),
							  allocator);
	if (m_filter_coef_layer.size())
	    (*layersArray)[layersArray->Size() - 1].AddMember("filterCoeffsLayer",
							      m_filter_coef_layer.c_str(),
							      allocator);
	if (m_filter_initial_keep)
	    (*layersArray)[layersArray->Size() - 1].AddMember("initialCondSmooth",
							      m_filter_initial_keep,
							      allocator);
	if (m_filter_noncausal)
	    (*layersArray)[layersArray->Size() - 1].AddMember("noncausal",
							      m_filter_noncausal,
							      allocator);
	if (m_dilation_size > 1)
	    (*layersArray)[layersArray->Size() - 1].AddMember("dilation_size",
							      m_dilation_size,
							      allocator);
	
	if (m_filter_mode == FILTERING_LAYER_MODE_TRAINABLE_WEIGHTS){
	    (*layersArray)[layersArray->Size() - 1].AddMember("filter_mode",
							      m_filter_mode,
							      allocator);	    
	}
	
	if (m_filter_mode == FILTERING_LAYER_REVERB){
	    (*layersArray)[layersArray->Size() - 1].AddMember("reverb_noise",
							      m_reverb_IR_noise,
							      allocator);

	    (*layersArray)[layersArray->Size() - 1].AddMember("filterLength",
							      m_filter_length,
							      allocator);

	    (*layersArray)[layersArray->Size() - 1].AddMember("filter_mode",
							      m_filter_mode,
							      allocator);
	    
	    (*layersArray)[layersArray->Size() - 1].AddMember("reverb_decay_scale",
							      m_reverb_decayScale,
							      allocator);
	    
	    (*layersArray)[layersArray->Size() - 1].AddMember("reverb_decay_shift",
							      m_reverb_decayShift,
							      allocator);
	    
	    (*layersArray)[layersArray->Size() - 1].AddMember("reverb_DC_gain_0dB",
							      m_reverb_normalize,
							      allocator);
	}
    }
    

    template <typename TDevice>
    void FilteringLayer<TDevice>::reduceOutputBuffer()
    {
	this->resizeOutputBuffer(this->parallelSequences() * this->size());	
	this->setSaveMemoryFlag(true);
	printf("\t[mem saved]");
    }
    
    template <typename TDevice>
    int FilteringLayer<TDevice>::outputBufPtrBias(const int timeStepTimesParallel,
						  const int nnState)
    {
	if (this->getSaveMemoryFlag()){
	    return timeStepTimesParallel * this->size();
	}else{
	    return 0;
	}
    }	

    template <typename TDevice>
    void FilteringLayer<TDevice>::linkTargetLayer(Layer<TDevice> &targetLayer)
    {
	if (targetLayer.name() == m_filter_coef_layer){
	    m_filter_coef_layer_ptr = &targetLayer;
	    m_filter_length = targetLayer.size();
	}
	return;
    }

    
    template <typename TDevice>
    void FilteringLayer<TDevice>::clearAllBuffers()
    {
	this->clearOutputBuffer();
	this->__clearLocalMem();
    }

    template <typename TDevice>
    void FilteringLayer<TDevice>::resizeAllBuffers(const int timeLength)
    {
	this->resizeOutputBuffer(timeLength * this->parallelSequences() * this->size());
	this->__allocateLocalMem();
    }


    template <typename TDevice>
    void FilteringLayer<TDevice>::logAllBuffers(helpers::vecPoolManager<TDevice> &vecPoolMng,
						bool flag_add)
    {
	// for output buffer
	Layer<TDevice>::logAllBuffers(vecPoolMng, flag_add);
	if (m_filter_mode == FILTERING_LAYER_REVERB){
	    if (m_reverb_IR_noise)
		vecPoolMng.addOrRemoveNewVec(this->size(), flag_add);
	    vecPoolMng.addOrRemoveNewVec(this->size() * 2, flag_add);
	    vecPoolMng.addOrRemoveNewVec(this->size(), flag_add);
	    vecPoolMng.addOrRemoveNewVec(this->size(), flag_add);
	}
    }

    template <typename TDevice>
    void FilteringLayer<TDevice>::swapAllBuffers(
	helpers::vecPoolManager<TDevice> &vecPoolMng,
	bool flag_get)
    {
	Layer<TDevice>::swapAllBuffers(vecPoolMng, flag_get);
	if (m_filter_mode == FILTERING_LAYER_REVERB){
	    if (m_reverb_IR_noise)
		vecPoolMng.getSwapVector(m_reverb_IR_noise_vec, this->getLayerID(),
					 this->size(), flag_get);

	    vecPoolMng.getSwapVector(m_reverb_norm_buf_vec, this->getLayerID(),
				     this->size() * 2, flag_get);
	    
	    vecPoolMng.getSwapVector(m_reverb_decay_coef_vec, this->getLayerID(),
				     this->size(), flag_get);
	    
	    vecPoolMng.getSwapVector(m_reverb_grad_buf, this->getLayerID(),
				     this->size(), flag_get);
	}
    }
    
    template class FilteringLayer<Cpu>;
    template class FilteringLayer<Gpu>;
}
