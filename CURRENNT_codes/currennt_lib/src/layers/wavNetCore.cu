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
 *****************************************************************************/

#include "wavNetCore.hpp"

#include "../helpers/getRawPointer.cuh"
#include "../helpers/Matrix.hpp"
#include "../helpers/JsonClasses.hpp"
#include "../helpers/misFuncs.hpp"
#include "../activation_functions/Logistic.cuh"
#include "../activation_functions/Tanh.cuh"
#include "../MacroDefine.hpp"

#include <thrust/transform.h>
#include <thrust/transform_reduce.h>
#include <thrust/for_each.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/fill.h>
#include <thrust/random.h>
#include <boost/foreach.hpp>
#include <boost/shared_ptr.hpp>
#include <boost/algorithm/string.hpp>
#include <boost/lexical_cast.hpp>
#include <vector>
#include <stdexcept>
#include <fstream>

#include "../activation_functions/Tanh.cuh"
#include "../activation_functions/Logistic.cuh"
#include "../activation_functions/Identity.cuh"
#include "../activation_functions/Relu.cuh"

#include "../Configuration.hpp"

// unconditional WaveNet core
#define  NN_WAVENETCORE_MODE_UNCOND   0

// the first conditional WaveNet core in the network
#define  NN_WAVENETCORE_MODE_COND_INI 1

// conditional WaveNet cores after the first core 
#define  NN_WAVENETCORE_MODE_COND_FOL 2   


namespace internal{
namespace {

    // tanh(x[0:dim/2]) * sig(x[dim/2:dim])
    struct tanhSigMerge
    {
	
	int         shiftBuf;
	int         outputSize;
	real_t     *coreBuf;
	const char *patTypes;
	
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int dimIdx    = t.get<1>() % outputSize;
	    int timeIdx   = t.get<1>() / outputSize;

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0.0;
	    }else{
		int idx = timeIdx * 2 * outputSize + dimIdx - shiftBuf;
		t.get<0>() = (activation_functions::Tanh::fn(coreBuf[idx]) *
			      activation_functions::Logistic::fn(coreBuf[idx + outputSize]));
	    }
	}
    };

    // gradient w.r.t tanh(x[0:dim/2]) * sig(x[dim/2:dim])
    struct tanhSigMergeGradient
    {

	int         outputSize;
	real_t     *coreBuf;
	real_t     *errors;
	const char *patTypes;
	
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int dimIdx    = t.get<1>() % outputSize;
	    int timeIdx   = t.get<1>() / outputSize;

	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0.0;
	    }else{
		
		if (dimIdx < (outputSize/2)){
		    int idx = timeIdx * outputSize + dimIdx;
		    /* Fatal Errors: Tanh::derive(y), y should be the output of tanh(x)
		       Here, we need to use the function 1-Tanh(x) * Tanh(x)
		     */
		    /*
		    t.get<0>() = (activation_functions::Tanh::deriv(coreBuf[idx]) *
				  activation_functions::Logistic::fn(coreBuf[idx + outputSize/2]) *
				  errors[timeIdx * outputSize / 2 + dimIdx]);*/
		    real_t tmp = activation_functions::Tanh::fn(coreBuf[idx]);
		    t.get<0>() = (((real_t)1.0 - tmp * tmp) *
				  activation_functions::Logistic::fn(coreBuf[idx + outputSize/2]) *
				  errors[timeIdx * outputSize / 2 + dimIdx]);
		    
		}else{
		    int idx = timeIdx * outputSize + dimIdx;
		    /*
		    t.get<0>() = (activation_functions::Tanh::fn(coreBuf[idx - outputSize/2]) *
				  activation_functions::Logistic::deriv(coreBuf[idx]) *
				  errors[timeIdx * outputSize /2 + dimIdx - outputSize / 2]);*/
		    real_t tmp = activation_functions::Logistic::fn(coreBuf[idx]);
		    t.get<0>() = (activation_functions::Tanh::fn(coreBuf[idx - outputSize/2]) *
				  (tmp * ((real_t)1.0 - tmp)) *
				  errors[timeIdx * outputSize /2 + dimIdx - outputSize / 2]);
		}
		
	    }
	}
    };

    // Load linguistic/acoustic features from source buffer to buffer of wavNetCore
    // If the source is at the frame-level, do up-sampling
    // If mean/std is provided, do normalization
    struct loadLinguisticFeature
    {
	int  featureDim;
	int  paralNum;
	int  maxFeatureLength;
	bool exInputResolutionOne;
	const real_t *sourceData;
	const real_t *frameIndex;
	const real_t *contextMV;
	const char *patTypes;
	
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int dimIdx  = t.get<1>() % featureDim;
	    int timeIdx = t.get<1>() / featureDim;
	    int paralIdx= timeIdx % paralNum;
	    int featIdx = 0;
	    
	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0.0;
	    }else{

		if (exInputResolutionOne){
		    // If exInput has already upsampled the conditions
		    // directly load the data
		    featIdx = timeIdx;
		}else{
		    // otherwise, use the frame index to load the input conditiona
		    // features at a lower temporal rate
		    featIdx = frameIndex[timeIdx] * paralNum + paralIdx;
		}
		
		if (frameIndex[timeIdx] >= maxFeatureLength){
		    t.get<0>() = 0.0;
		    
		}else if(contextMV){
		    
		    t.get<0>() = ((sourceData[featIdx * featureDim + dimIdx] - contextMV[dimIdx])/
				  ((contextMV[dimIdx + featureDim]<1e-5f)?
				   (1.0):
				   (contextMV[dimIdx + featureDim])));
		}else{
		    t.get<0>() = sourceData[featIdx * featureDim + dimIdx];
		}
		
	    }
	}
    };

    // input + tanh(linguistic/acoustic Features)
    struct AddLinguisticFeature
    {
	int     featureDim;
	real_t *contextTanh;
	const real_t *fromConv;
	const char   *patTypes;

	int     shiftConv;
	int     shiftOut;
	
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int dimIdx  = t.get<1>() % featureDim;
	    int timeIdx = t.get<1>() / featureDim;
	    int fromConvIdx = t.get<1>() - shiftConv;
	    
	    if (patTypes[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0.0;
		if (contextTanh != NULL) contextTanh[t.get<1>()] = 0.0;
	    }else{
		if (contextTanh != NULL){
		    contextTanh[t.get<1>()] = activation_functions::Tanh::fn(t.get<0>());
		    t.get<0>() = fromConv[fromConvIdx] + contextTanh[t.get<1>()];
		}else{
		    t.get<0>() = fromConv[fromConvIdx] + activation_functions::Tanh::fn(t.get<0>());
		}
	    }
	}
    };

    // grad of linguistic/acoustic features 
    struct AddLinguisticFeatureGrad
    {
        
        __host__ __device__ void operator() (const thrust::tuple<real_t&, const real_t&> &t) const
        {
            real_t delta = activation_functions::Tanh::deriv(t.get<0>()) * t.get<1>();
            t.get<0>() = delta;
        }
    };

    // propagate gradients to the layer that produces the linguistic/acoustic features
    // If that layer generates linguistic/acoustic features at the frame-level,
    // the gradients within the frame should be accumulated
    struct SumGradientsForExternalInput
    {
	// from the perspective of externalLayer
	int featureDim;
	int resolution;
	int maxTimeLength;
	int parall;
	
	real_t     *inputGrad;
	const char *patTypesEx;
	const char *patTypes;
	
	__host__ __device__ void operator() (const thrust::tuple<real_t&, int> &t) const
	{
	    int timeIdx  = t.get<1>() / featureDim;
	    int dimIdx   = t.get<1>() % featureDim;
	    int timeRel  = timeIdx    / parall;	    
	    int paraIdx  = timeIdx    % parall;
	    
	    if (patTypesEx[timeIdx] == PATTYPE_NONE){
		t.get<0>() = 0.0;
		return;
	    }else{
		int idx;
		for (int i = 0; i<resolution; i++){
		    idx = (timeRel * resolution + i) * parall + paraIdx;
		    if (idx < maxTimeLength && patTypes[idx] != PATTYPE_NONE)
			t.get<0>() += inputGrad[idx * featureDim + dimIdx];
		}
		return;
	    }
	}

    };

}
}


namespace layers{

    // To read a float data vector from dataPath
    // (not used anymore)
    int tmp_readRealData(const std::string dataPath, Cpu::real_vector &data)
    {
	// 
	std::ifstream ifs(dataPath.c_str(), std::ifstream::binary | std::ifstream::in);
	if (!ifs.good())
	    throw std::runtime_error(std::string("Fail to open ")+dataPath);
	
	// get the number of we data
	std::streampos numEleS, numEleE;
	long int numEle;
	numEleS = ifs.tellg();
	ifs.seekg(0, std::ios::end);
	numEleE = ifs.tellg();
	numEle  = (numEleE-numEleS)/sizeof(real_t);
	ifs.seekg(0, std::ios::beg);
	
	// read in the data
	data = Cpu::real_vector(numEle, 0);
	real_t tempVal;
	for (unsigned int i = 0; i<numEle; i++){
	    ifs.read ((char *)&tempVal, sizeof(real_t));
	    data[i] = tempVal;
	}
	//thrust::copy(tempVec.begin(), tempVec.end(), data.begin());
	ifs.close();
	return numEle;
    }

    template <typename TDevice>
    WavNetCore<TDevice>::WavNetCore(const helpers::JsonValue &layerChild,
				    const helpers::JsonValue &weightsSection,
				    Layer<TDevice>           &precedingLayer,
				    int                       maxSeqLength,
				    int                       layerID)
	: TrainableLayer<TDevice>(layerChild, weightsSection, 0,
				  ((layerChild->HasMember("contextDim")) ? 
				   ((*layerChild)["contextDim"].GetInt()) : (0)) * 2,
				  precedingLayer, maxSeqLength, layerID)
	, m_exInputLayer         (NULL)
	, m_exInputContextResone (false)
    {

	// dimension of the conditional features
	m_contextDim   = ((layerChild->HasMember("contextDim")) ? 
			  ((*layerChild)["contextDim"].GetInt()) : (0));

	// (not used anymore)
	m_wavCoreOpt   = ((layerChild->HasMember("wavCoreOpt")) ? 
			  ((*layerChild)["wavCoreOpt"].GetInt()) : (0));

	// path to the file that stores the mean and std of conditional features
	m_contextMVStr = ((layerChild->HasMember("contextMV")) ?
			  ((*layerChild)["contextMV"].GetString()) : "");

	// equal to this->output().size() / this->size()
	// =  maximum length of utterance * number of parallel sequences
	m_maxSeqLengthPara = this->maxSeqLength() * this->parallelSequences();
	
	// check
	if ((2 * this->size()) != precedingLayer.size()){
	    printf("\n\t Size of this layer should = 1/2 * previous layer size");
	    throw std::runtime_error("Error in network.jsn");
	}
	
	// print the information
	printf("\n\tWavNet core operation: context [%d] dim\n", m_contextDim);

	// Other memory will be allocated after linking target layers
	// this->__allocateLocalMem();

	// load mean/std from m_contextMVStr if necessary
	cpu_real_vector tmp(m_contextDim * 2, 0.0);
	if (m_contextMVStr.size() && m_contextDim > 0){
	    if (tmp_readRealData(m_contextMVStr, tmp) != m_contextDim * 2)
		throw std::runtime_error("context mean variance dim unequal");
	    m_contextMV = tmp;
	}else{
	    m_contextMV.clear();
	}

	// length of the conditional feature sequence
	m_contextCurMaxLength = -1;
    }

    template <typename TDevice>
    WavNetCore<TDevice>::~WavNetCore()
    {
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::__allocateLocalMem()
    {
	// length of the output buffer (maybe != maxSeqlength in the mem-save mode)
	long int curSeqLengthPara = this->outputs().size() / this->size();

	// length of the maxSeqLength, which is determined by the data, not mem-save mode
	long int maxSeqLengthPara = this->m_maxSeqLengthPara;
	
	// allocate memory for lingusitic/acoustic_features + input_features
	cpu_real_vector tmp(curSeqLengthPara * this->size() * 2, 0.0);
	m_coreBuf        = tmp;

	// for tanh(linguistic/acoustic features)
	if (this->flagTrainingMode())
	    m_contextTanhBuf = tmp;
	else
	    m_contextTanhBuf.clear();

        if (this->getLayerMode() == NN_WAVENETCORE_MODE_COND_INI ||
	    this->getLayerMode() == NN_WAVENETCORE_MODE_UNCOND){
	    // if linguistic/acoustic features will be loaded
	    
	    // Buffer to save the features at sampling-point-level 
	    tmp.resize(maxSeqLengthPara * m_contextDim, 0.0);
	    m_contextBuf    = tmp;
	    
	    if (m_exInputLayer == NULL)
		throw std::runtime_error("Fail to link external layer for wavenetc");

	    // Buffer to save the features from input data IO
	    tmp.resize(misFuncs::getResoLength(
			maxSeqLengthPara / this->parallelSequences(),
			m_exInputLayer->getResolution(), 1) *
		       this->parallelSequences() * m_contextDim +
		       maxSeqLengthPara, 0.0);
	    m_contextRawBuf = tmp;

	    // Buffer for grad of conditional features
	    if (this->flagTrainingMode())
		m_contextGraBuf = m_contextBuf;
	    else
		m_contextGraBuf.clear();

	    // Temporal resolution of linguistic/acoustic features
	    // For features at the frame-level, m_exInputContextResone = true
	    if (m_exInputLayer->getResolution() == 1)
		m_exInputContextResone = true;
	    
	}else if (this->getLayerMode() == NN_WAVENETCORE_MODE_COND_FOL){
	    // unconditional wavNet core
	    m_contextBuf.clear();
	    m_contextGraBuf.clear();
	    m_contextRawBuf.clear();

	}else{
	    throw std::runtime_error("Unknown wavNetCore layer mode");	    
	}
	    
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::__clearLocalMem()
    {
	m_coreBuf.clear();        m_coreBuf.shrink_to_fit();
	m_contextTanhBuf.clear(); m_contextTanhBuf.shrink_to_fit();
	m_contextBuf.clear();     m_contextBuf.shrink_to_fit();
	m_contextGraBuf.clear();  m_contextGraBuf.shrink_to_fit();
	m_contextRawBuf.clear();  m_contextRawBuf.shrink_to_fit();
    }
    
    template <typename TDevice>
    void WavNetCore<TDevice>::exportLayer(const helpers::JsonValue     &layersArray, 
					  const helpers::JsonAllocator &allocator) const
    {
        TrainableLayer<TDevice>::exportLayer(layersArray, allocator);
	(*layersArray)[layersArray->Size() - 1].AddMember("contextDim", m_contextDim, allocator);
	(*layersArray)[layersArray->Size() - 1].AddMember("wavCoreOpt", m_wavCoreOpt, allocator);
	if (m_contextMVStr.size())
	    (*layersArray)[layersArray->Size() - 1].AddMember("contextMV", m_contextMVStr.c_str(),
							      allocator);

    }


    template <typename TDevice>
    void WavNetCore<TDevice>::__loadContextBuff()
    {
	// Load linguistic/acoustic features from data IO	

	if (m_iniWavCoreC && m_contextDim > 0){
	    // if this is the first waveNetCore in the network
	    
	    if (m_exInputLayer != NULL){
		// if the linguistic/acoustic features are provided by a
		// conditional network, get the features from that network
		// m_exInputLayer points to the output layer of that conditional network
		thrust::copy(m_exInputLayer->outputs().begin(),
			     m_exInputLayer->outputs().end(),
			     m_contextRawBuf.begin() + m_maxSeqLengthPara);
	    }else{
		// if the linguistic/acoustic features are directly loaded
		// from data IO, load the features in loadSequences()
	    }

	    // Load the data to contextBuf, do up-sampling if necessary
	    {{	
		internal::loadLinguisticFeature fn1;
		fn1.featureDim = m_contextDim;
		fn1.paralNum   = this->parallelSequences();
		fn1.maxFeatureLength = m_contextCurMaxLength;
		fn1.sourceData = (helpers::getRawPointer(m_contextRawBuf) +
				  m_maxSeqLengthPara);
		fn1.frameIndex = helpers::getRawPointer(m_contextRawBuf);
		fn1.patTypes   = helpers::getRawPointer(this->patTypes());
		fn1.exInputResolutionOne = m_exInputContextResone;
		fn1.contextMV  = ((m_contextMV.size() == m_contextDim * 2)?
				  helpers::getRawPointer(m_contextMV) : NULL);
		
		int n = this->curMaxSeqLength() * this->parallelSequences() * m_contextDim;
		thrust::for_each(
			thrust::make_zip_iterator(
				thrust::make_tuple(m_contextBuf.begin(),
						   thrust::counting_iterator<int>(0))),
			thrust::make_zip_iterator(
				thrust::make_tuple(m_contextBuf.begin()              + n,
						   thrust::counting_iterator<int>(0) + n)),
			fn1);
	    }}
	    
	}else{

	    // For wavNetCores after the first wavNetCore in the network
	    // just directly use the loaded features from the first wavNetCore
	    // No need to load the features again
	    return;
	}
    }
    
    template <typename TDevice>
    void WavNetCore<TDevice>::loadSequences(const data_sets::DataSetFraction &fraction,
					    const int nnState)
    {
	// Load data sequence information

	
	TrainableLayer<TDevice>::loadSequences(fraction, nnState);

	if (m_iniWavCoreC && m_contextDim > 0){
	    // For the first wavNetCore 
	    
	    if (m_contextRawBuf.size()<1){
		printf("\nFail to initialize m_contextRawBuf in WavNetCore\n");
		throw std::runtime_error("Error in CURRENNT");
	    }
	    
	    // load the input time step index
	    thrust::copy(fraction.inputs().begin(), fraction.inputs().end(),
			 m_contextRawBuf.begin());

	    // get the length of the input data utterance
	    m_contextCurMaxLength = fraction.maxExInputLength();

	    // 
	    if (m_exInputLayer == NULL){
		
		// Load the external linguistic features from fractionData
		// check the fixed external data
		if (fraction.externalInputSize() != m_contextDim){
		    printf("Linguistic feature dim  %d mismatch",
			   fraction.externalInputSize());
		    throw std::runtime_error("Error in WaveNetCore of CURRENNT");
		}
		// Note: __loadContextBuff also write to m_contextRawBuf
		// but they are used in different cases
		thrust::copy(fraction.exInputData().begin(),
			     fraction.exInputData().end(),
			     (m_contextRawBuf.begin() +
			      m_maxSeqLengthPara));
	    
	    }else{

		// If conditional features are provided by a trainable network,
		// features will be loaded in __loadContextBuf()
		if (m_exInputLayer->size()!= m_contextDim){
		    printf("Trainable external input dim  %d mismatch", m_exInputLayer->size());
		    throw std::runtime_error("Unmatched trainable external feature dimension");
		}
	    }
	}else{
	    // for wavNetCores after the first wavNetCore, 
	    // there is no need to read the linguistic features again
	    // just use the feature buffer of the first wavNetCore
	}
    }
    
    template <typename TDevice>
    const std::string& WavNetCore<TDevice>::type() const
    {
        static std::string s;
        if (s.empty()) s = "wavnetc";
        return s;
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::linkTargetLayer(Layer<TDevice> &targetLayer)
    {
	// Corresponding to NeuralNetwork.cpp:
	//  Step1: set the flag in initial WaveNet-core and link following WaveNet-core
	//  Step2: link the linguistic context to the initial Wavenet core
	
	if (targetLayer.type() == std::string("wavnetc")){

	    if (targetLayer.name() == this->name()){
		// This is the initial wavNetCore layer
		m_iniWavCoreC = true;
		m_iniWavCPtr  = NULL;

		if (m_contextDim)
		    this->setLayerMode(NN_WAVENETCORE_MODE_COND_INI);
		else
		    this->setLayerMode(NN_WAVENETCORE_MODE_UNCOND);
		
	    }else{
		// This is the following wavNetCore layers
		// The following wavNetCore layers will directly read the m_contextBuf
		// from the initial wavNetCore layer, no need to read it again
		m_iniWavCoreC = false;
		m_iniWavCPtr  = dynamic_cast<WavNetCore<TDevice>*>(&(targetLayer));
		if (m_iniWavCPtr == NULL)
		    throw std::runtime_error("Fail to link wavnetc");
		
		printf("\n\tWaveNet core: %s copies condition from %s",
		       this->name().c_str(),
		       m_iniWavCPtr->name().c_str());
		this->setLayerMode(NN_WAVENETCORE_MODE_COND_FOL);
		this->__allocateLocalMem();
		
	    }
	    m_exInputLayer = NULL;
	    
	}else{
	    // When the conditional features are processed by a trainable network
	    if (m_iniWavCoreC){
		m_exInputLayer = dynamic_cast<layers::TrainableLayer<TDevice>*>(&(targetLayer));
		if (m_exInputLayer == NULL)
		    throw std::runtime_error("Fail to link external layer for wavenetc");
		if (m_contextDim != m_exInputLayer->size())
		    throw std::runtime_error("External input layer size != contextDim");
		printf("\n\tWaveNet core: %s uses condition from %s", this->name().c_str(),
		       m_exInputLayer->name().c_str());

		this->__allocateLocalMem();

	    }else{
		throw std::runtime_error("Impossible bug");		
	    }
	}
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::computeForwardPass(const int nnState)
    {
	if (this->getSaveMemoryFlag())
	    throw std::runtime_error("Memory save mode should be turned off");
	int timeLength = this->curMaxSeqLength() * this->parallelSequences();

	// forward propagation
	// input: input_feature, lingusitic/acoustic feature(optional)
	// output Z:
	//      step1. X = W1 . linguistic/acoustic_feature
	//      step2. Y = input_feature + tanh( X )
	//      step3. Z = tanh(Y[0:dim/2]) * sig(Y[dim/2:])
	//       
	
	// Step0. initialze the gradients for external input
	if (m_iniWavCoreC && this->m_exInputLayer != NULL)
	    thrust::fill(m_contextGraBuf.begin(), m_contextGraBuf.end(), 0.0);

	// load linguistic/acoustic feature if necessary
	__loadContextBuff();
	
	
	// Step1. transform the linguistic context
	if (m_contextDim == 0){
	    thrust::fill(m_coreBuf.begin(), m_coreBuf.end(), 0.0);
	    
	}else{
	    // transformation matrix
	    helpers::Matrix<TDevice> weightsMatrix(&this->weights(), m_contextDim, 2*this->size());
	    // 
	    helpers::Matrix<TDevice> plOutputsMatrix(&(m_iniWavCoreC?(this->m_contextBuf):
						       (m_iniWavCPtr->m_contextBuf)), 
						     m_contextDim, timeLength);
	    helpers::Matrix<TDevice> outputsMatrix(&this->m_coreBuf, this->size()*2, timeLength);
	    outputsMatrix.assignProduct(weightsMatrix, true, plOutputsMatrix, false);
	}
	
	// Step2. sum input
	/*thrust::transform(this->precedingLayer().outputs().begin(),
			  this->precedingLayer().outputs().begin() + timeLength * this->size() * 2,
			  m_coreBuf.begin(), m_coreBuf.begin(), thrust::plus<real_t>());*/
	// Step2. convOutput + tanh(Linguistic)
	{
	    internal::AddLinguisticFeature fn2;
	    fn2.featureDim  = this->size() * 2;
	    fn2.patTypes    = helpers::getRawPointer(this->patTypes());
	    fn2.fromConv    = helpers::getRawPointer(this->precedingLayer().outputs());
	    fn2.contextTanh = (this->flagTrainingMode()?
			       (helpers::getRawPointer(m_contextTanhBuf)) : NULL);

	    fn2.shiftConv   = 0;
	    fn2.shiftOut    = 0;
	    
	    int n = timeLength * this->size() * 2;
	    thrust::for_each(
               thrust::make_zip_iterator(
		  thrust::make_tuple(m_coreBuf.begin(),
				     thrust::counting_iterator<int>(0))),
	       thrust::make_zip_iterator(
		  thrust::make_tuple(m_coreBuf.begin()                 + n,
				     thrust::counting_iterator<int>(0) + n)),
	       fn2);
	}

	// Step3. transform as output tanh(x1) * sig(x2)
	{
	    internal::tanhSigMerge fn1;
	    fn1.outputSize = this->size();
	    fn1.coreBuf    = helpers::getRawPointer(m_coreBuf);
	    fn1.patTypes   = helpers::getRawPointer(this->patTypes());
	    fn1.shiftBuf   = 0;
	    int n = timeLength * this->size();
	    thrust::for_each(
               thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin(),
				     thrust::counting_iterator<int>(0))),
	       thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin()           + n,
				     thrust::counting_iterator<int>(0) + n)),
	       fn1);
	}
    }
    
    template <typename TDevice>
    void WavNetCore<TDevice>::computeForwardPass(const int timeStep, const int nnState)
    {
	// Forward propagation for the n-th time step
	// This is used for online / memory-save generation
	
	// Only allocate the memory space for a few time steps
	// Please check pp46-55 http://tonywangx.github.io/pdfs/CURRENNT_WAVENET.pdf
	
	int effTimeStep = timeStep * this->parallelSequences();
	int shiftPre    = this->precedingLayer().outputBufPtrBias(effTimeStep, nnState);
	int shiftCur    = this->outputBufPtrBias(effTimeStep, nnState);

	// Load the data to contextBuf only at the first time step
	if (timeStep == 0) __loadContextBuff();
	
	if (m_contextDim == 0){
	    thrust::fill(m_coreBuf.begin() + (effTimeStep * this->size() - shiftCur) * 2,
			 m_coreBuf.begin() +((effTimeStep * this->size() - shiftCur) * 2 + 
					     + this->size() * 2 * this->parallelSequences()),
			 0.0);
	}else{
	    // Step1. transform the linguistic context
	    helpers::Matrix<TDevice> weightsMatrix(&this->weights(), m_contextDim, 2*this->size());
	
	    helpers::Matrix<TDevice> plOutputsMatrix(&(m_iniWavCoreC?(this->m_contextBuf):
						       (m_iniWavCPtr->m_contextBuf)), m_contextDim,
						     this->parallelSequences(),
						     effTimeStep * m_contextDim);
	    helpers::Matrix<TDevice> outputsMatrix(&this->m_coreBuf, this->size() * 2,
						   this->parallelSequences(),
						   (effTimeStep * this->size() - shiftCur) * 2);
	
	    outputsMatrix.assignProduct(weightsMatrix, true, plOutputsMatrix, false);
	}
	
	// Step2. sum input
	/*thrust::transform(this->precedingLayer().outputs().begin()+effTimeStep*this->size()*2,
			  this->precedingLayer().outputs().begin() +
			  (effTimeStep + this->parallelSequences()) * this->size() * 2,
			  m_coreBuf.begin() + effTimeStep * this->size() * 2,
			  m_coreBuf.begin() + effTimeStep * this->size() * 2,
			  thrust::plus<real_t>());*/
	{
	    internal::AddLinguisticFeature fn2;
	    fn2.featureDim  = this->size() * 2;
	    fn2.patTypes    = helpers::getRawPointer(this->patTypes());
	    fn2.fromConv    = helpers::getRawPointer(this->precedingLayer().outputs());
	    fn2.contextTanh = (this->flagTrainingMode()?
			       (helpers::getRawPointer(m_contextTanhBuf)):NULL);

	    fn2.shiftConv   = shiftPre;
	    fn2.shiftOut    = shiftCur * 2;
	    
	    int st = effTimeStep * this->size() * 2;
	    int et = (effTimeStep + this->parallelSequences()) * this->size() * 2;
	    thrust::for_each(
               thrust::make_zip_iterator(
		  thrust::make_tuple(m_coreBuf.begin() + (st - shiftCur * 2) ,
				     thrust::counting_iterator<int>(0) + st)),
	       thrust::make_zip_iterator(
		  thrust::make_tuple(m_coreBuf.begin() + (et - shiftCur * 2),
				     thrust::counting_iterator<int>(0) + et)),
	       fn2);
	}


	// Step3. transform as output tanh(x1) * sig(x2)
	{
	    internal::tanhSigMerge fn1;
	    fn1.outputSize = this->size();
	    fn1.coreBuf    = helpers::getRawPointer(m_coreBuf);
	    fn1.patTypes   = helpers::getRawPointer(this->patTypes());
	    fn1.shiftBuf   = shiftCur * 2;
		
	    int st = effTimeStep * this->size();
	    int et = (effTimeStep + this->parallelSequences()) * this->size();
	    thrust::for_each(
               thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin() + st - shiftCur,
				     thrust::counting_iterator<int>(0) + st)),
	       thrust::make_zip_iterator(
		  thrust::make_tuple(this->outputs().begin() + et - shiftCur,
				     thrust::counting_iterator<int>(0) + et)),
	       fn1);
	}
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::computeBackwardPass(const int nnState)
    {
	// Backward propagation
	
	if (this->getSaveMemoryFlag())
	    throw std::runtime_error("Memory save mode should be turned off");
	
	int timeLength = this->curMaxSeqLength() * this->parallelSequences();


	// for Z = tanh(Y[0:dim]) * sig(Y[dim/2:])
	// get grad for Y
	{
	    internal::tanhSigMergeGradient fn1;
	    fn1.outputSize = this->size() * 2;
	    fn1.coreBuf    = helpers::getRawPointer(m_coreBuf);
	    fn1.errors     = helpers::getRawPointer(this->outputErrors());
	    fn1.patTypes   = helpers::getRawPointer(this->patTypes());
	    
	    int n = timeLength * this->size() * 2;
	    thrust::for_each(
               thrust::make_zip_iterator(
		thrust::make_tuple(this->precedingLayer().outputErrors().begin(),
				     thrust::counting_iterator<int>(0))),
	       thrust::make_zip_iterator(
		thrust::make_tuple(this->precedingLayer().outputErrors().begin() + n,
				     thrust::counting_iterator<int>(0) + n)),
	       fn1);
	}

	if (m_contextDim == 0)
	    return;

	// for Y = input_features + tanh (X)
	// get grad for X
	{
	    internal::AddLinguisticFeatureGrad fn;

            int n = timeLength * this->size() * 2;
            thrust::for_each(
             thrust::make_zip_iterator(
	      thrust::make_tuple(m_contextTanhBuf.begin(),
				 this->precedingLayer().outputErrors().begin())),
	     thrust::make_zip_iterator(
	      thrust::make_tuple(m_contextTanhBuf.begin() + n,
				 this->precedingLayer().outputErrors().begin() + n)),
                fn);

	}

	// for X = W1 . linguistic/acoustic_feature
	// get grad for W1
	helpers::Matrix<TDevice> weightUpdatesMatrix(&this->_weightUpdates(),
						     m_contextDim, this->size() * 2);
	helpers::Matrix<TDevice> plOutputsMatrix(&(m_iniWavCoreC?(this->m_contextBuf):
						   (m_iniWavCPtr->m_contextBuf)), 
						 m_contextDim, timeLength);
	helpers::Matrix<TDevice> outputsMatrix  (&m_contextTanhBuf,
						 this->size()*2, timeLength);
	weightUpdatesMatrix.assignProduct(plOutputsMatrix, false, outputsMatrix, true);

	
	// for X = W1 . linguistic/acoustic_feature
	// get grad for linguistic/acoustic_feature
	// and add the gradients to the buffer
	if (m_iniWavCoreC == false){
	    // Gradients to the trainable external input layers
	    if (m_iniWavCPtr->m_exInputLayer != NULL){
		// accumulate the gradients from wavenets
		helpers::Matrix<TDevice> gradBuf(&m_iniWavCPtr->m_contextGraBuf,
						 m_contextDim, timeLength);
		helpers::Matrix<TDevice> weightsMatrix(&this->weights(),
						       m_contextDim, 2*this->size());		
		helpers::Matrix<TDevice> outputsMatrix  (&m_contextTanhBuf,
							 this->size()*2, timeLength);
		gradBuf.addProduct(weightsMatrix, false, outputsMatrix, false);   
	    }
	}else{
	    
	    if (this->m_exInputLayer != NULL){
		// accumulate the gradients from wavenets
		helpers::Matrix<TDevice> gradBuf(&this->m_contextGraBuf,
						 m_contextDim, timeLength);
		helpers::Matrix<TDevice> weightsMatrix(&this->weights(),
						       m_contextDim, 2*this->size());		
		helpers::Matrix<TDevice> outputsMatrix  (&m_contextTanhBuf,
							 this->size()*2, timeLength);
		gradBuf.addProduct(weightsMatrix, false, outputsMatrix, false);
		
		// return the gradients to the previous layer
		thrust::fill(this->m_exInputLayer->outputErrors().begin(),
			     this->m_exInputLayer->outputErrors().end(), 0.0);
		
		internal::SumGradientsForExternalInput fn2;
		
		fn2.featureDim = this->m_exInputLayer->size();
		fn2.resolution = this->m_exInputLayer->getResolution();
		fn2.maxTimeLength = timeLength;
		fn2.parall     = this->parallelSequences();
		fn2.inputGrad  = helpers::getRawPointer(this->m_contextGraBuf);
		fn2.patTypesEx = helpers::getRawPointer(this->m_exInputLayer->patTypes());
		fn2.patTypes   = helpers::getRawPointer(this->patTypes());
		int m = (this->m_exInputLayer->size() * this->m_exInputLayer->curMaxSeqLength() *
			 this->parallelSequences());
		thrust::for_each(
		   thrust::make_zip_iterator(
			thrust::make_tuple(this->m_exInputLayer->outputErrors().begin(),
					   thrust::counting_iterator<int>(0))),
		   thrust::make_zip_iterator(
			thrust::make_tuple(this->m_exInputLayer->outputErrors().begin() + m,
					   thrust::counting_iterator<int>(0) + m)),
		   fn2);
	    }
	}
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::computeBackwardPass(const int timeStep, const int nnState)
    {
	throw std::runtime_error("WavNetCore computeBackwardPass(timeStep) not implemented");
    }
    
    template <typename TDevice>
    void WavNetCore<TDevice>::reduceOutputBuffer()
    {
	//Layer<TDevice>::reduceOutputBuffer();
	this->resizeOutputBuffer(this->parallelSequences() * this->size());
	m_coreBuf.resize(this->parallelSequences() * this->size() * 2, 0.0);
	m_coreBuf.shrink_to_fit();
	this->setSaveMemoryFlag(true);
	printf("\t[mem saved]");
    }

    template <typename TDevice>
    int  WavNetCore<TDevice>::outputBufPtrBias(const int timeStepTimesParallel, const int nnState)
    {
	if (this->getSaveMemoryFlag())
	    return timeStepTimesParallel * this->size();
	else
	    return 0;
    }
    

    template <typename TDevice>
    std::vector<int> WavNetCore<TDevice>::dependLayerIDs()
    {
	std::vector<int> tmp;
	tmp.push_back(this->precedingLayer().getLayerID());
	if (!m_iniWavCoreC)
	    tmp.push_back(this->m_iniWavCPtr->getLayerID());
	return tmp;
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::clearAllBuffers()
    {
	this->clearOutputBuffer();
	this->__clearLocalMem();
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::resizeAllBuffers(const int timeLength)
    {
	this->resizeOutputBuffer(timeLength * this->parallelSequences() * this->size());
	this->__allocateLocalMem();
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::logAllBuffers(helpers::vecPoolManager<TDevice> &vecPoolMng,
					    bool flag_add)
    {
	// for output buffer
	Layer<TDevice>::logAllBuffers(vecPoolMng, flag_add);
	
	// m_coreBuf
	vecPoolMng.addOrRemoveNewVec(this->size() * 2, flag_add);

	// m_contextTanhBuf
	if (this->flagTrainingMode())
	    vecPoolMng.addOrRemoveNewVec(this->size() * 2, flag_add);

	if (this->getLayerMode() == NN_WAVENETCORE_MODE_COND_INI ||
	    this->getLayerMode() == NN_WAVENETCORE_MODE_UNCOND){
	    // m_contextBuf
	    vecPoolMng.addOrRemoveNewVec(this->m_contextDim, flag_add);
	    
	    // m_contextRawBuf
	    vecPoolMng.addOrRemoveNewVec(this->m_contextDim + 1, flag_add);

	    // m_contextGradBuf
	    if (this->flagTrainingMode())
		vecPoolMng.addOrRemoveNewVec(this->m_contextDim, flag_add);
	}
    }

    template <typename TDevice>
    void WavNetCore<TDevice>::swapAllBuffers(helpers::vecPoolManager<TDevice> &vecPoolMng,
					     bool flag_get)
    {
	// for output buffer
	Layer<TDevice>::swapAllBuffers(vecPoolMng, flag_get);
	
	// m_coreBuf
	vecPoolMng.getSwapVector(m_coreBuf, this->getLayerID(),
				 this->size() * 2, flag_get);
	
	// m_contextTanhBuf
	if (this->flagTrainingMode())
	    vecPoolMng.getSwapVector(m_contextTanhBuf, this->getLayerID(),
				     this->size() * 2, flag_get);

	if (this->getLayerMode() == NN_WAVENETCORE_MODE_COND_INI ||
	    this->getLayerMode() == NN_WAVENETCORE_MODE_UNCOND){
	    // m_contextBuf
	    vecPoolMng.getSwapVector(m_contextBuf, this->getLayerID(),
				     this->m_contextDim, flag_get);
	    
	    // m_contextRawBuf
	    vecPoolMng.getSwapVector(m_contextRawBuf, this->getLayerID(),
	    			     this->m_contextDim + 1, flag_get);

	    // m_contextGradBuf
	    if (this->flagTrainingMode())
		vecPoolMng.getSwapVector(m_contextGraBuf, this->getLayerID(),
					 this->m_contextDim, flag_get);
	    
	    // In mem-save mode for MA model,
	    // maxLength() will become NETWORK_TEMPMAXLENGTH_FOR_MA
	    // The initial value of m_maxSeqLengthPara is NETWORK_TEMPMAXLENGTH_FOR_MA
	    //
	    // After memory allocation, the value of m_maxSeqLengthPara should be fixed
	    // It should change according to the size of this->outputs()
	    if (flag_get)
		m_maxSeqLengthPara = this->outputs().size() / this->size();
	}
	
    }
    
    template class WavNetCore<Cpu>;
    template class WavNetCore<Gpu>;
    
}
