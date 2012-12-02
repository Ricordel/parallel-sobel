#include <cuda.h>
#include <omp.h>



/* Pour gérer des images grandes, passer un paramètre nPxPerThreads est chiant, car ça décale
   tout tout le temps. Mais faut le faire...
*/




// shared memory does not work
#define USE_SHARED_MEM 0




/* CUDA is implicitly C++ code, this is needed so out symbols are not mangled */
extern "C" {

#include "dbg.h"
#include "sobel.h"


struct pixel {
        unsigned char R;
        unsigned char G;
        unsigned char B;
        unsigned char A;
};


__constant__ kernel_t kernelX = { {-1, 0, 1}, 
                                  {-2, 0, 2},
                                  {-1, 0, 1} };

__constant__ kernel_t kernelY = { {-1, -2, -1},
                                  { 0,  0,  0},
                                  { 1,  2,  1} };



/* Return the next power of 2 of n, or n if n is already a power of 2 */
static inline uint32_t getNextPowerOf2(uint32_t n) {
    uint32_t cur = n;
    uint32_t rslt = 1;
    /* Find the previous power of 2 */
    while (cur >>= 1) {
        rslt <<= 1;
    }

    if (rslt == n) {
        return n;
    } else {
        return (rslt << 1);
    }
}



__device__ inline unsigned char greyscale_value(struct pixel *pImage, uint32_t pxNum)
{
        /* Get the GreyScale value of our pixel */
        unsigned char R, G, B, greyVal;
        R = pImage[pxNum].R;
        G = pImage[pxNum].G;
        B = pImage[pxNum].B;

        greyVal = (R + G + B) / 3;

        return greyVal;
}




/* pxNum is the index of the central pixel for the convolution in the pImage array */
__device__ inline int32_t convolution_by_3(struct pixel *pImage, kernel_t kernel,
                                           uint32_t pxNum, uint32_t width, uint32_t height)
{
        int32_t grad = 0;
        /* Line below */
        grad += kernel[0][0] * greyscale_value(pImage, pxNum + width + 1);
        grad += kernel[0][1] * greyscale_value(pImage, pxNum + width);
        grad += kernel[0][2] * greyscale_value(pImage, pxNum + width - 1);

        /* current line */
        grad += kernel[1][0] * greyscale_value(pImage, pxNum + 1);
        grad += kernel[1][1] * greyscale_value(pImage, pxNum);
        grad += kernel[1][2] * greyscale_value(pImage, pxNum - 1);

        /* line above */
        grad += kernel[2][0] * greyscale_value(pImage, pxNum - width + 1);
        grad += kernel[2][1] * greyscale_value(pImage, pxNum - width);
        grad += kernel[2][2] * greyscale_value(pImage, pxNum - width - 1);

        return grad;
}




#if 0
__global__ void sobel_unnorm_kernel(struct pixel *pInImageData, uint16_t *pOutImageData,
                                    uint32_t width, uint32_t height, int numWorkerThreads)
{
    return;
}
    
#else


__global__ void sobel_unnorm_kernel(struct pixel *pInImageData, uint16_t *pOutImageData,
                                    uint32_t width, uint32_t height, uint32_t basePx)
{
    uint32_t pxNum = blockIdx.x * blockDim.x + threadIdx.x + basePx;


    /* If we are on a border, do nothing */
    if (pxNum < width /* First line */
            || pxNum % width == 0 /* First column */
            || pxNum % width == width - 1 /* last column */
            || pxNum >= (width * (height - 1)) /* Last line */
       )
    {
        pOutImageData[pxNum] = 0;
    }
    else
    {
        int32_t gradX = convolution_by_3(pInImageData, kernelX, pxNum, width, height);
        int32_t gradY = convolution_by_3(pInImageData, kernelY, pxNum, width, height);
        float gradX_float = (float) gradX;
        float gradY_float = (float) gradY;

        uint16_t normGrad = (uint32_t) sqrt(gradX_float*gradX_float + gradY_float*gradY_float);

        pOutImageData[pxNum] = normGrad;
    }

}
#endif



/* This kernel will only handle the normalization.
   The size of the block MUST be a power of two, otherwise the behaviour
   is undefined (and most probably incorrect). */
__global__ void norm_image_kernel(uint16_t *pMaxGrads, uint16_t *pNonNormalized, struct pixel *pOutImage,
                                  uint32_t width, uint32_t height, uint32_t basePx)
{
    uint32_t pxNum = blockIdx.x * blockDim.x + threadIdx.x + basePx;

    uint16_t maxGrad = pMaxGrads[0];

    //XXX divergent kernels, not super efficient

    /* If we are on a border, do nothing */
    if (   pxNum < width /* First line */
            || pxNum % width == 0 /* First column */
            || pxNum % width == width - 1 /* last column */
            || pxNum >= (width * (height - 1)) /* Last line */
       )
    {
        //XXX Que faire ici ?
        pOutImage[pxNum].R = 0;
        pOutImage[pxNum].G = 0;
        pOutImage[pxNum].B = 0;
        pOutImage[pxNum].A = 255; /* Full opacity */
    }
    else
    {
        unsigned char greyVal = (255 * pNonNormalized[pxNum]) / maxGrad;
        pOutImage[pxNum].R = greyVal;
        pOutImage[pxNum].G = greyVal;
        pOutImage[pxNum].B = greyVal;
        pOutImage[pxNum].A = 255; /* Full transparency */
    }

}



__global__ void max_reduction_kernel(uint16_t *pMaxGrads, uint32_t width,
                                     uint32_t height, uint32_t nPxPerThread)
{
    extern __shared__ uint16_t sData[]; /* Contains the data for the local reduction */

    uint32_t pxNum = blockIdx.x * blockDim.x + threadIdx.x;
    uint32_t tid = threadIdx.x;

    /* For each of the pixels the thread is responsible for */

    /* Each thread copies its pixel, and maybe more if needed */
    if (pxNum < width * height) {
        sData[tid] = pMaxGrads[pxNum];
    } else {
        sData[tid] = 0;
    }

    for (int i = 1; i < nPxPerThread; i++) {
        uint32_t nextPxIdx = pxNum + blockDim.x * gridDim.x * i;
        if (nextPxIdx < width * height) {
            sData[tid] = max(sData[tid], pMaxGrads[nextPxIdx]);
        }
    }

    __syncthreads();

    /* Now, reduce in parallel to find the max */
    for (uint32_t stride = blockDim.x / 2; stride > 0; stride = stride >> 1) {
        if (tid < stride) { /* If we are on the lowest part of the remaining array */
            sData[tid] = max(sData[tid], sData[tid + stride]);
        }

        __syncthreads();
    }

    if (tid == 0) {
        pMaxGrads[blockIdx.x] = sData[0];
    }

    /* At the end of that kernel, pOutData contains the max value of each block */
}





void log_time(FILE *logFile, char *testName, uint32_t size, double t, int numThreads)
{
        //XXX should do something
}



int sobel(struct image *const pInImage, struct image *pOutImage)
{
        check_warn (pInImage->type == RGBA, "In image must be RGBA");

        uint32_t width = pInImage->width;
        uint32_t height = pInImage->height;

        cudaError_t ret;
        struct cudaDeviceProp deviceProp;

        // We will only use one device, the first one
        ret = cudaGetDeviceProperties(&deviceProp, 0);

        int maxThreadsPerBlock = deviceProp.maxThreadsDim[0];
        int nbPx = width * height;

        /* Number of running threads per block, take care of the case
           where there are very little pixels */
        int nThreadsPerBlock = nbPx > maxThreadsPerBlock ? maxThreadsPerBlock : nbPx;

        /* And number of blocks to cover all pixels */
        int maxConcurrentBlocks = deviceProp.maxGridSize[0];
        int maxConcurrentThreads = maxConcurrentBlocks * maxThreadsPerBlock;
        
        /* Allocate memory on the device for in image, and non-normalized gradient norms. */
        struct pixel *inImageDevice = NULL;
        uint16_t *outNonNormalized = NULL;

        ret = cudaMalloc((void **)&inImageDevice, width * height * sizeof(struct pixel));
        check_warn (ret == cudaSuccess, "Failed to allocate memory for in image on the device");

        ret = cudaMalloc((void **)&outNonNormalized, width * height * sizeof(uint16_t));
        check_warn (ret == cudaSuccess, "Failed to allocate memory for out image on the device");

        /* Copy the input image to the device */
        ret = cudaMemcpy(inImageDevice, pInImage->data, width * height * sizeof(struct pixel),
                         cudaMemcpyHostToDevice);
        check_warn (ret == cudaSuccess, "Failed to copy input image to device");


        /* Now, we need to invoke the sobel kernel, that will make convolutions.
           We must be careful to invoke it as much times as necessary considering
           that there might be more pixels than allocatable threads. */
        //XXX later
        for (uint32_t basePx = 0; basePx < nbPx; basePx += maxConcurrentThreads) {

            /* Don't use more blocks than necessary */
            uint32_t runningThreads = min(nbPx - basePx, maxConcurrentThreads);
            uint32_t nBlocks = runningThreads / nThreadsPerBlock +
                              (runningThreads % nThreadsPerBlock == 0 ? 0 : 1);

            printf("Will call sobel_unnorm_kernel with basePx = %u, nBlocks = %u,"
                    "nThreadsPerBlock = %u, maxConcurrentThreads = %u\n",
                    basePx, nBlocks, nThreadsPerBlock, maxConcurrentThreads);
                                    
            /* No local memory for this kernel, although it could benefit it.
               XXX see later ! */
            sobel_unnorm_kernel <<< nBlocks, nThreadsPerBlock >>> (inImageDevice, outNonNormalized, width, height, basePx);
            cudaDeviceSynchronize(); //XXX ne devrait pas servir
        }

        //XXX For debug ppurposes: fihd the real max */
        {
            uint16_t *maxes = (uint16_t *)calloc(width * height, sizeof(uint16_t));
            ret = cudaMemcpy(maxes, outNonNormalized, width * height * sizeof(uint16_t), cudaMemcpyDeviceToHost);
            check_warn (ret == cudaSuccess, "failed to memcpy");

            for (int i = 0; i < 10; i++) {
                printf("%u ", maxes[i]);
            }
            for (int i = 0; i < width*height; i++) {
                if (maxes[i] == 1337) {
                    /*printf("maxes[%d] = %u\n", i, maxes[i]);*/
                }
            }

            uint32_t maxPos = 0;
            uint16_t theMax = 0;
            for (uint32_t i = 0; i < width * height; i++) {
                if (maxes[i] > theMax) {
                    theMax = maxes[i];
                    maxPos = i;
                }
            }
            printf("The real max is: %u, at %u\n", theMax, maxPos);
        }


        /* Now, we need to get the maximum gradient norm value located in outNonNormalized.
           We don't need the input image any longer */
        cudaFree(inImageDevice);


        /* Allocate memory for max grad reduction, and copy non-normalized data */
        uint16_t *maxGrads = NULL;

        ret = cudaMalloc((void **)&maxGrads, width * height * sizeof(uint16_t));
        check_warn (ret == cudaSuccess, "Failed to allocate memory for out image on the device");
        ret = cudaMemcpy(maxGrads, outNonNormalized, width * height * sizeof(uint16_t),
                         cudaMemcpyDeviceToDevice);
        check_warn (ret == cudaSuccess, "Failed to copy maxGrads from device to device");

        /* And invoke iteratively out max-reduction kernel */
        /* Each pass will reduce the number of elements by a factor of nThreadsPerBlock */
        //XXX Sûr ?
        //XXX Faire encore attention au nombre de threads trop petit pour le nombre de pixels...
        //XXX PLUS TARD ! Pour ça, à cet endroit-là, juste gérer ça au moment du load
        //XXX depuis la mémoire globale: gérer 10 px chacun si nécessaire.


        //XXX This must handle the case where there are not enough threads
        //XXX per pixels.
        

        uint32_t i = 0;//XXX for debug
        uint32_t remainingElems = nbPx;
        while (remainingElems > 1) {
            uint32_t threadsPerBlock = min(remainingElems, maxThreadsPerBlock);
            /* Be careful, the kernel only works if the number of threads per block is
               a power of 2 */
            threadsPerBlock = getNextPowerOf2(threadsPerBlock);
            /* And don't allocate more blocks than possible. If there are too many
               pixels, some blocks will handle several pixels */
            uint32_t nBlocks = min(remainingElems / threadsPerBlock + (remainingElems % threadsPerBlock == 0 ? 0 : 1),
                                   maxConcurrentBlocks);
            uint32_t nThreads = threadsPerBlock * nBlocks;
            uint32_t nPxPerThread = remainingElems / nThreads + (nbPx % nThreads == 0 ? 0 : 1);
                                   
            uint32_t sharedMem = threadsPerBlock * sizeof(uint16_t);

            printf("Before invocation n° %d, nBlocks = %u, threadsPerBlock = %u, sharedMem = %u,"
                    "remainingElems = %u, %u px per thread\n", i, nBlocks, threadsPerBlock, sharedMem,
                    remainingElems, nPxPerThread);

            max_reduction_kernel <<< nBlocks, threadsPerBlock, sharedMem >>> (maxGrads, width, height, nPxPerThread);

            remainingElems = remainingElems / threadsPerBlock + (remainingElems % threadsPerBlock == 0 ? 0 : 1);
            i++;
        }
            

        /* For debug, get max */
        uint16_t maxGrad;
        ret = cudaMemcpy(&maxGrad, maxGrads, sizeof(int16_t), cudaMemcpyDeviceToHost);
        check_warn(ret == cudaSuccess, "Failed to memcpy");
        printf("Max grad : %u\n", maxGrad);


        //XXX faire un truc pour les bords aussi... padder avec des zéros DANS LA MÉMOIRE ALLOUÉE SUR LE DEVICE

        /* Allocate memory for the final resulting image */
        struct pixel *outNormalizedDevice = NULL;
        ret = cudaMalloc((void **) &outNormalizedDevice, width * height * sizeof(struct pixel));
        check_warn(ret == cudaSuccess, "Failed to allocate memory for outNormalizedDevice");


        /* Now, it's time to call the kernel that normalises the image gradients and puts it
           into pixels */
        for (uint32_t basePx = 0; basePx < nbPx; basePx += maxConcurrentThreads) {

            printf("Will call norm_image_kernel with basePx = %u\n", basePx);

            /* Don't use more blocks than necessary */
            uint32_t runningThreads = min(nbPx - basePx, maxConcurrentThreads);
            uint32_t nBlocks = runningThreads / nThreadsPerBlock +
                              (runningThreads % nThreadsPerBlock == 0 ? 0 : 1);
                                    
            norm_image_kernel <<< nBlocks, nThreadsPerBlock >>>
                (maxGrads, outNonNormalized, outNormalizedDevice, width, height, basePx);
        }

        
        /* Copy the result from device, and we're done */

        pOutImage->width = width;
        pOutImage->height = height;
        pOutImage->type = RGBA;
        pOutImage->data = (unsigned char*)calloc(pOutImage->width * pOutImage->height, sizeof(struct pixel));

        cudaMemcpy(pOutImage->data, outNormalizedDevice, width * height * sizeof(struct pixel),
                   cudaMemcpyDeviceToHost);
        return 0;



        //XXX ancien code
#if 0

        ret = cudaMalloc((void **)&outImageDevice, width * height * sizeof(struct pixel));
        check_warn (ret == cudaSuccess, "Failed to allocate memory for out image on the device");

        /* We will also need memory for the max-reduction, and the non-normalized gradient norms */





        dim3 threadsPerBlock(maxLinearThreads);

        int gridLength = (width * height) / maxLinearThreads +
                        ((width * height) % maxLinearThreads == 0 ? 0 : 1);

        /* If that's too much blocks, reduce, and each thread will handle several pixels
           (handled in the kernel) */
        if (gridLength > deviceProp.maxGridSize[0]) {
            gridLength = deviceProp.maxGridSize[0];
        }

        uint32_t numWorkerThreads = gridLength * maxLinearThreads;

        dim3 nBlocks(gridLength);


        printf("%d blocks of %d threads each, for %d total worker threads, and %d pixels\n",
                gridLength, maxLinearThreads, gridLength * maxLinearThreads, width*height);


        struct pixel *inImageDevice;
        uint16_t *outImageDevice;
        struct pixel *outNormalizedDevice;

        /* Allocate memory on the device for both images (in and out) */
        ret = cudaMalloc((void **)&inImageDevice, width * height * sizeof(struct pixel));
        check_warn (ret == cudaSuccess, "Failed to allocate memory for in image on the device");

        ret = cudaMalloc((void **)&outImageDevice, width * height * 4 * sizeof(uint16_t));
        check_warn (ret == cudaSuccess, "Failed to allocate memory for out image on the device");

        ret = cudaMalloc((void **)&outNormalizedDevice, width * height * sizeof(struct pixel));
        check_warn (ret == cudaSuccess, "Failed to allocate memory for out normalized, image on the device");

        /* Copy The input image on the device */
        ret = cudaMemcpy(inImageDevice, pInImage->data, width * height * sizeof(struct pixel),
                         cudaMemcpyHostToDevice);
        check_warn (ret == cudaSuccess, "Failed to copy the image to the device");


        /* Unnormalized version */
        uint16_t *pUnNormalizedOut = NULL;
        pUnNormalizedOut = (uint16_t *)calloc(width*height, sizeof(uint16_t));

        /* Normalized output */
        //XXX
        struct pixel *pNormalizedOut = NULL;
        pNormalizedOut = (struct pixel *)calloc(width*height, sizeof(struct pixel));

        /* Allocate memory for the resulting image */
        pOutImage->width = pInImage->width;
        pOutImage->height = pInImage->height;
        pOutImage->type = RGBA;
        pOutImage->data = (unsigned char*)calloc(pOutImage->width * pOutImage->height, sizeof(struct pixel));
        /*check_mem(pOutImage->data);*/

        /* And launch the kernel */
        sobel_unnorm_kernel <<< nBlocks, threadsPerBlock >>> (inImageDevice, outImageDevice, width, height, numWorkerThreads);

        ret = cudaMemcpy(pUnNormalizedOut, outImageDevice,
                         width * height * sizeof(uint16_t), cudaMemcpyDeviceToHost);
        check_warn (ret == cudaSuccess, "Kernel failed: %s", cudaGetErrorString(ret));


        /* Normalize, on CPU for the moment */
        uint16_t maxGrad = 0;
        //XXX maxPos for debug only
        uint32_t maxPos = 0;
        for (uint32_t i = 0; i < width*height; i++) {
                if (pUnNormalizedOut[i] > maxGrad) {
                        maxGrad = pUnNormalizedOut[i];
                        maxPos = i;
                }
        }
        printf("Max: %u, at %u\n", maxGrad, maxPos);

#if 1
        //XXX this should NOT be necessary
        ret = cudaMemcpy(outImageDevice, pUnNormalizedOut,
                         width * height * sizeof(uint16_t), cudaMemcpyHostToDevice);

        /* Normalization kernel */
        norm_image_kernel <<< nBlocks, threadsPerBlock >>> (outImageDevice, outNormalizedDevice,
                                                            maxGrad, width, height, numWorkerThreads);


        cudaMemcpy(pOutImage->data, (unsigned char *) outNormalizedDevice,
                   width*height*sizeof(struct pixel), cudaMemcpyDeviceToHost);

        for (int i = 0; i < 20; i++) {
            printf("%d ", pOutImage->data[i]);
        }
#else

        for (uint32_t i = 0; i < width*height; i++) {
                unsigned char greyVal = (255 * pUnNormalizedOut[i]) / maxGrad;
                pOutImage->data[4*i] = greyVal;
                pOutImage->data[4*i + 1] = greyVal;
                pOutImage->data[4*i + 2] = greyVal;
                pOutImage->data[4*i + 3] = 255; /* full opacity */
        }
#endif




        cudaFree(inImageDevice);
        cudaFree(outImageDevice);
        cudaFree(outNormalizedDevice);
        return 0;
        //XXX need a cleanup for image in case of failure.

/*error:*/
        /*cudaFree(inImageDevice);*/
        /*cudaFree(outImageDevice);*/
        /*free_and_null(pOutImage->data);*/
        /*return -1;*/
#endif /* old code */
}




} /* extern "C" */
