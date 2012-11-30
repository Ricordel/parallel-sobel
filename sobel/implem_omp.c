#include <papi.h>

#include <stdlib.h>
#include <math.h>
#include <omp.h>


#include "dbg.h"

#include "sobel.h"



/*
 * Simple initialiszation of the X-direction gradient kernel
 */
static inline int initKernelX(kernel_t kernelX)
{
        kernelX[0][0] = -1;
        kernelX[0][1] = 0;
        kernelX[0][2] = 1;

        kernelX[1][0] = -2;
        kernelX[1][1] = 0;
        kernelX[1][2] = 2;

        kernelX[2][0] = -1;
        kernelX[2][1] = 0;
        kernelX[2][2] = 1;

        return 0;
}


/*
 * Simple initialiszation of the X-direction gradient kernel
 */
static inline int initKernelY(kernel_t kernelY)
{
        kernelY[0][0] = -1;
        kernelY[0][1] = -2;
        kernelY[0][2] = -1;

        kernelY[1][0] = 0;
        kernelY[1][1] = 0;
        kernelY[1][2] = 0;

        kernelY[2][0] = 1;
        kernelY[2][1] = 2;
        kernelY[2][2] = 1;

        return 0;
}



/* Compute one value by convoluting a 3x3 kernel over a 3x3 portion of the image
 *
 * in: pInImage         Pointer to the image to convolute
 * in: pKernel          Pointer to the kernel to apply
 * in: row, col         Coordinates of the point to get by convolution
 * out: pPixel          Pointer to the pixel to write
 * 
 *
 *
 * Formula for the convolution of a 3x3 kernel f with an image I :
 * forall (i, j)
 *      y(i, j) = sum(k = -1..1) { sum(l = -1..1) { f(k, l) * I(i - k, j - l) } }
 *
 * As in C, arrays start to 0, we reindex those loops:
 *      y(i, j) = sum_(k = 0..2) { sum_(l = 0..2) { f(k-1, l-1) * I(i - k + 1, j - l + 1) } }
 *
 * As we will only convolute by a 3x3 kernel, we unroll this directly, it will simplify
 * border-conditions checking, and could play nicely with the optimizer.
 *
 * Unrolled version:
 *      y(i, j) =   f(0, 0) * I(i+1 j+1)
 *                + f(0, 1) * I(i+1, j)
 *                + f(0, 2) * I(i+1, j-1)
 *
 *                + f(1, 0) * I(i, j+1)
 *                + f(1, 1) * I(i, j)
 *                + f(1, 2) * I(i, j-1)
 *
 *                + f(2, 0) * I(i-1, j+1)
 *                + f(2, 1) * I(i-1, j)
 *                + f(2, 2) * I(i-1, j-1)
 *
 * We see from the above formula that there is a problem for i = 0, j = 0, i = M, j = N
 * where the image is of size MxN. In such a condition, this function will fail. The edge
 * conditions must be handeled in the calling code.
 */
static inline void convolution_3_by_3(struct image *const pInImage, kernel_t kernel,
                                      uint32_t row, uint32_t col,
                                      int16_t *restrict pPixel)
{
        uint32_t w = pInImage->width;
        int16_t acc = 0;
        acc += kernel[0][0] * pInImage->data[(row + 1)*w + col + 1];
        acc += kernel[0][1] * pInImage->data[(row + 1)*w + col];
        acc += kernel[0][2] * pInImage->data[(row + 1)*w + col - 1];

        acc += kernel[1][0] * pInImage->data[row*w + col + 1];
        acc += kernel[1][1] * pInImage->data[row*w + col];
        acc += kernel[1][2] * pInImage->data[row*w + col - 1];

        acc += kernel[2][0] * pInImage->data[(row - 1)*w + col + 1];
        acc += kernel[2][1] * pInImage->data[(row - 1)*w + col];
        acc += kernel[2][2] * pInImage->data[(row - 1)*w + col - 1];

        *pPixel = acc;
}


/*
 * XXX on pourrait aussi étendre virtuellement la matrice de base avec des 0 sur
 * XXX les bords. Ca devrait marcher, et c'est plus propre. Peut-être pas le plus
 * XXX important pour l'instant.
 ***** Edge conditions *****
 * We see from the above formula that there is a problem for i = 0, j = 0, i = M, j = N
 * where the image is of size MxN. We will simply ignore them while computing the
 * convolution, and then copy row 1 n row 0, col 1 in col 0, col M-1 in col M, and
 * row N-1 in row N.
 * For instance, if the following matrix resulted from the convolution (where ? represent
 * values that could not be computed):
 *
 *    ? ? ? ? ?                                           1 1 2 3 3
 *    ? 1 2 3 ?                                           1 1 2 3 3
 *    ? 4 5 6 ?   it would be artificially extented to    4 4 5 6 6
 *    ? 7 8 9 ?                                           7 7 8 9 9
 *    ? ? ? ? ?                                           7 7 8 9 9
 *                                                      
 */
int convolution3(struct image *const pInImage, kernel_t kernel, struct matrix *pOutMatrix)
{
        check_null(pInImage);
        check_null(pOutMatrix);
        check_warn(pOutMatrix->data == NULL, "Overwrite non-null pointer possible leak");
{

        /* First, allocate memory for the outMatrix, and set its features */
        pOutMatrix->width = pInImage->width;
        pOutMatrix->height = pInImage->height;
        pOutMatrix->data = calloc(pInImage->width * pInImage->height, sizeof(int16_t));
        check_mem(pOutMatrix->data);


        /* Make the convolution where it's possible */
#pragma omp parallel for shared (pOutMatrix)
        for (uint32_t row = 1; row < pInImage->height - 1; row++) {
                for (uint32_t col = 1; col < pInImage->width - 1; col++) {
                        convolution_3_by_3(pInImage, kernel, row, col,
                                        &pOutMatrix->data[row*pOutMatrix->width + col]);
                }
        }

        /* Fill the missing rows with what we arbitrarily decided. Be careful,
         * corners cannot be filled yet, so from 1 to width - 1. */
#pragma omp parallel for shared(pOutMatrix)
        for (uint32_t col = 1; col < pOutMatrix->width - 1; col++) {
                pOutMatrix->data[col] = pOutMatrix->data[pOutMatrix->width + 1];

                uint32_t startBeforeLastRow = pOutMatrix->width * (pOutMatrix->height - 2);
                uint32_t startLastRow = pOutMatrix->width * (pOutMatrix->height - 1);
                pOutMatrix->data[startLastRow + col] = pOutMatrix->data[startBeforeLastRow + col];
        }

        /* Now first and last columns, including corners. Iterate row by row. */
#pragma omp parallel for shared(pOutMatrix)
        for (uint32_t startRow = 0; startRow < pOutMatrix->height; startRow += pOutMatrix->width) {
                pOutMatrix->data[startRow] = pOutMatrix->data[startRow + 1];

                pOutMatrix->data[startRow + pOutMatrix->width - 1] =
                        pOutMatrix->data[startRow + pOutMatrix->width - 2];
        }

        return 0;
error:
        reset_matrix(pOutMatrix);
        return -1;
}
}


/* Return the norm2 of a vector */
static inline int16_t norm2(int16_t x, int16_t y)
{
        return sqrt(x*x + y*y);
}




/* Works on GreyScale images */
static inline void normalize_matrix_to_image(struct matrix *const pMat, struct image *pImg)
{
        int16_t max = ~0;
        int16_t loc_max = ~0; // min value


#pragma omp parallel firstprivate(loc_max) shared(max)
        {
#pragma omp for /* Get the max on our chunk */
        for (uint32_t px = 0; px < pMat->width * pMat->height; px++) {
                if (pMat->data[px] > loc_max) {
                        loc_max = pMat->data[px];
                }
        }

#pragma omp critical /* And get the max of all loc_maxes */
        {
                for (int i = 0; i < omp_get_num_threads(); i++) {
                        if (loc_max > max) {
                                max = loc_max;
                        }
                }
        } /* end of critical */
        } /* end of parallel */



#pragma omp parallel for shared(pImg)
        for (uint32_t px = 0; px < pMat->width * pMat->height; px++) {
                pImg->data[px] = (unsigned char) ((pMat->data[px] * 255) / max);
        }


}




/* Output a GreyScale image */
int gradient_norm(struct matrix *const pInMatrixX, struct matrix *const pInMatrixY, struct image *pOutImage)
{
        check_null(pInMatrixX);
        check_null(pInMatrixY);
        check_null(pOutImage);
        check(pOutImage->data == NULL, "Overwriting non-null pointer, possible leak");
        check (pInMatrixX->width == pInMatrixY->width && pInMatrixX->height == pInMatrixY->height,
                        "Both matrix must have same dimensions, found (%d, %d) and (%d, %d)",
                        pInMatrixX->width, pInMatrixX->height, pInMatrixY->width, pInMatrixY->height);
{
        pOutImage->width = pInMatrixX->width;
        pOutImage->height = pInMatrixX->height;
        pOutImage->type = GreyScale;
        pOutImage->data = calloc(pOutImage->width * pOutImage->height, sizeof(unsigned char));
        check_mem(pOutImage->data);

        /* The returned norm of the gradient might be far bigger than 255. Hence, we keep more
         * precision on the result, and later normalize from 0 to 255 */
        struct matrix unNormalizedGradient = MATRIX_INITIALIZER;
        unNormalizedGradient.width = pOutImage->width;
        unNormalizedGradient.height = pOutImage->height;
        unNormalizedGradient.data = calloc(pOutImage->width * pOutImage->height, sizeof(int16_t));
        check_mem(unNormalizedGradient.data);


#pragma omp parallel for shared(unNormalizedGradient)
        for (uint32_t px = 0; px < pOutImage->width * pOutImage->height; px++) {
                unNormalizedGradient.data[px] = norm2(pInMatrixX->data[px], pInMatrixY->data[px]);
        }

        normalize_matrix_to_image(&unNormalizedGradient, pOutImage);

        return 0;
error:
        reset_matrix(pOutImage);
        return -1;
}
}



/* Simple extension from Grey values to R = G = B = grey, and A = 0
 * See header file for full documentation. */
int greyScale_to_RGBA(struct image *const pGSImage, struct image *pRGBAImage)
{
        check (pGSImage->type == GreyScale,
                "The image to convert must be GreyScale, %s found", IMAGE_TYPE_STR(pRGBAImage->type));
        check_warn(pRGBAImage->data == NULL, "Will overwrite non-NULL ptr, potential leak");
{
        const uint32_t width  = pGSImage->width;
        const uint32_t height = pGSImage->height;
        
        pRGBAImage->width  = width;
        pRGBAImage->height = height;
        pRGBAImage->type   = RGBA;
        pRGBAImage->data = calloc(width * height * 4, sizeof(unsigned char));
        check_mem(pRGBAImage->data);
        
#pragma omp parallel for shared(pRGBAImage)
        for (uint32_t i = 0; i < width * height; i++) {
                uint32_t greyVal = pGSImage->data[i];
                pRGBAImage->data[4*i]     = greyVal;
                pRGBAImage->data[4*i + 1] = greyVal;
                pRGBAImage->data[4*i + 2] = greyVal;
                pRGBAImage->data[4*i + 3] = 255; /* fully opaque */
        }

        return 0;
error:
        reset_matrix(pRGBAImage);
        return -1;
}
}





/*
 * Takes the mean of R, G, B ad grey value. Alpha channel is ignored
 * See header file for full documentation
 */
int RGBA_to_greyScale(struct image *const pRGBAImage, struct image *pGSImage)
{
        check (pRGBAImage->type == RGBA, "The image to convert must be RGBA, %s found",
                                         IMAGE_TYPE_STR(pRGBAImage->type));
        check_warn(pGSImage->data == NULL, "Will overwrite non-NULL ptr, potential leak");
{
        const uint32_t width = pRGBAImage->width;
        const uint32_t height = pRGBAImage->height;

        pGSImage->width  = width;
        pGSImage->height = height;
        pGSImage->type   = GreyScale;
        pGSImage->data   = calloc(width * height, sizeof(unsigned char));
        check_mem(pGSImage->data);

#pragma omp parallel for shared(pGSImage)
        for (uint32_t i = 0; i < width * height; i++) {
                unsigned char R, G, B, greyVal;
                /* The RGBA image has 4 bytes by pixel */
                R = pRGBAImage->data[4 * i];
                G = pRGBAImage->data[4 * i + 1];
                B = pRGBAImage->data[4 * i + 2];
                greyVal = (R + G + B) / 3;

                pGSImage->data[i] = greyVal;
        }

        return 0;
error:
        reset_matrix(pGSImage);
        return -1;
}
}


int sobel(struct image *const pInImage, struct image *pOutImage)
{
#ifdef PROFILE
        double startRGB_to_GS, endRGB_to_GS;
        double startConvs, endConvs;
        double startGradNorm, endGradNorm;
        double startGS_to_RGB, endGS_to_RGB;
#endif

        check_null(pInImage);
        check_null(pOutImage);
        check (pOutImage->data == NULL, "Overwriting non-null ptr, possible leak");
{
        int ret;
        struct image greyScaleImageIn  = IMAGE_INITIALIZER;
        struct image greyScaleImageOut = IMAGE_INITIALIZER;
        struct matrix gradX = MATRIX_INITIALIZER;
        struct matrix gradY = MATRIX_INITIALIZER;
        kernel_t kernelX;
        kernel_t kernelY;

        
        tu_get_time(startRGB_to_GS );
        ret = RGBA_to_greyScale(pInImage, &greyScaleImageIn);
        tu_get_time(endRGB_to_GS );
        check (ret == 0, "Failed to convert to greyscale");


        ret = initKernelX(kernelX);
        check (ret == 0, "Failed to init kernel X");

        ret = initKernelY(kernelY);
        check (ret == 0, "Failed to init kernel Y");
        
        tu_get_time(startConvs );

        ret = convolution3(&greyScaleImageIn, kernelX, &gradX);
        check (ret == 0, "Failed to compute X gradient");

        ret = convolution3(&greyScaleImageIn, kernelY, &gradY);
        check (ret == 0, "Failed to compute Y gradient");

        tu_get_time(endConvs );

        tu_get_time(startGradNorm );
        ret = gradient_norm(&gradX, &gradY, &greyScaleImageOut);
        tu_get_time(endGradNorm );
        check (ret == 0, "Failed to compute gradieng norm");


        tu_get_time(startGS_to_RGB );
        ret = greyScale_to_RGBA(&greyScaleImageOut, pOutImage);
        tu_get_time(endGS_to_RGB );
        check (ret == 0, "Failed to convert result image to RGBA");

#ifdef PROFILE
        {
                int curNbThreads = get_env_num_threads();

                //XXX 1000 is arbitrary, just to get a non-null throughput
                log_time(stdout, "RGB to GS", 10000, endRGB_to_GS - startRGB_to_GS, curNbThreads);
                log_time(stdout, "convolutions", 10000, endConvs - startConvs, curNbThreads);
                log_time(stdout, "grad norm", 10000, endGradNorm - startGradNorm, curNbThreads);
                log_time(stdout, "GS to RGB", 10000, endGS_to_RGB - startGS_to_RGB, curNbThreads);
        }
#endif


        reset_matrix(&gradX);
        reset_matrix(&gradY);
        reset_matrix(&greyScaleImageIn);
        reset_matrix(&greyScaleImageOut);
        return 0;
error:
        reset_matrix(&gradX);
        reset_matrix(&gradY);
        reset_matrix(&greyScaleImageIn);
        reset_matrix(&greyScaleImageOut);
        reset_image(pOutImage);
        return -1;
}
}



void log_time(FILE *logFile, char *testName, uint32_t size, double t, int numThreads)
{
        if (logFile == NULL)
                return;

        fprintf(logFile, "{\"name\": \"%s\", \"size\": %u, \"nProcs\": %u, \"time\": %lf, \"throughput\": %lf},\n",
                testName, size, numThreads, t, (double)size/t);
}
