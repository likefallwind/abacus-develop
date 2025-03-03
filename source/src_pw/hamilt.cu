#include "global.h"
#include "hamilt.h"
#include "diago_david.h"
#include "diago_cg.cuh"
#include "cufft.h"
#include "../module_base/timer.h"

using namespace CudaCheck;

Hamilt::Hamilt() 
{
#ifdef __CUDA
    CHECK_CUSOLVER(cusolverDnCreate(&cusolver_handle));
#endif
}
Hamilt::~Hamilt() 
{
#ifdef __CUDA
    CHECK_CUSOLVER(cusolverDnDestroy(cusolver_handle));
#endif
}


__global__ void hamilt_cast_d2f(float *dst, double *src, int size)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i < size)
    {
        dst[i] = __double2float_rn(src[i]);
    }
}

__global__ void hamilt_cast_f2d(double *dst, float *src, int size)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i < size)
    {
        dst[i] = (double)(src[i]);
    }
}

__global__ void hamilt_cast_d2f(float2 *dst, double2 *src, int size)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i < size)
    {
        dst[i].x = __double2float_rn(src[i].x);
        dst[i].y = __double2float_rn(src[i].y);
    }
}

__global__ void hamilt_cast_f2d(double2 *dst, float2 *src, int size)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if(i < size)
    {
        dst[i].x = (double)(src[i].x);
        dst[i].y = (double)(src[i].y);
    }
}


void Hamilt::diagH_pw(
    const int &istep,
    const int &iter,
    const int &ik,
    const double *precondition,
    double &avg_iter)
{
	ModuleBase::TITLE("Hamilt","diagH_pw");
    ModuleBase::timer::tick("Hamilt", "diagH_pw");
    double avg = 0.0;

	// set ik0 because of mem_saver.
	// if mem_saver is not used, ik0=ik, as usual.
	// but if mem_saver is used, ik0=0.
	int ik0 = ik;

	if(GlobalV::CALCULATION=="nscf" && GlobalC::wf.mem_saver==1)
	{
		if(GlobalV::BASIS_TYPE=="pw")
		{
			// generate PAOs first, then diagonalize to get
			// inital wavefunctions.
			GlobalC::wf.diago_PAO_in_pw_k2(ik, GlobalC::wf.evc[0]);
		}
#ifdef __LCAO
		else if(GlobalV::BASIS_TYPE=="lcao_in_pw")
		{
			GlobalC::wf.LCAO_in_pw_k(ik, GlobalC::wf.wanf2[0]);
		}
#endif
		ik0 = 0;
	}

    if(GlobalV::BASIS_TYPE=="lcao_in_pw")
    {
		if(GlobalV::KS_SOLVER=="lapack")
		{
			assert(GlobalV::NLOCAL >= GlobalV::NBANDS);
        	this->diagH_subspace(
				ik,
				GlobalV::NLOCAL,
				GlobalV::NBANDS,
				GlobalC::wf.wanf2[ik0],
				GlobalC::wf.evc[ik0],
				GlobalC::wf.ekb[ik]);
		}
		else
		{
			GlobalV::ofs_warning << " The diago_type " << GlobalV::KS_SOLVER
				<< " not implemented yet." << std::endl; //xiaohui add 2013-09-02
            ModuleBase::WARNING_QUIT("Hamilt::diago","no implemt yet.");
		}
    }
    else
    {
        int ntry = 0;
        int notconv = 0;
        do
        {
	   		if(GlobalV::KS_SOLVER=="cg")
            {
				// qian change it, because it has been executed in diago_PAO_in_pw_k2
                
                double2 *d_wf_evc;
                double *d_wf_ekb;
                double2 *d_vkb_c;

                int nkb = GlobalC::ppcell.nkb;
                if(iter < 0)
                {
                    CHECK_CUFFT(cufftPlan3d(&GlobalC::UFFT.fft_handle, GlobalC::rhopw->nx, GlobalC::rhopw->ny, GlobalC::rhopw->nz, CUFFT_C2C));
                }
                else
                {
                    // CHECK_CUFFT(cufftPlan3d(&GlobalC::UFFT.fft_handle, GlobalC::rhopw->nx, GlobalC::rhopw->ny, GlobalC::rhopw->nz, CUFFT_Z2Z));
                }

                CHECK_CUDA(cudaMalloc((void**)&d_wf_evc, GlobalV::NBANDS * GlobalC::wf.npwx * GlobalV::NPOL * sizeof(double2)));
                CHECK_CUDA(cudaMalloc((void**)&d_wf_ekb, GlobalV::NBANDS * sizeof(double)));

                CHECK_CUDA(cudaMemcpy(d_wf_evc, 
                            GlobalC::wf.evc[ik0].c, 
                            GlobalV::NBANDS * GlobalC::wf.npwx * GlobalV::NPOL * sizeof(double2), cudaMemcpyHostToDevice));

                CHECK_CUDA(cudaMalloc((void**)&d_vkb_c, GlobalC::wf.npwx*nkb*sizeof(double2)));
                CHECK_CUDA(cudaMemcpy(d_vkb_c, GlobalC::ppcell.vkb.c, GlobalC::wf.npwx*nkb*sizeof(double2), cudaMemcpyHostToDevice));
                
                if ( iter > 1 || istep > 1 ||  ntry > 0)
                {
                    this->diagH_subspace_cuda(
						ik,
						GlobalV::NBANDS,
						GlobalV::NBANDS,
						d_wf_evc,
						d_wf_evc,
						d_wf_ekb,
                        d_vkb_c);

                    avg_iter += 1.0;
                }

                Diago_CG_CUDA<float, float2> f_cg_cuda;
                Diago_CG_CUDA<double, double2> d_cg_cuda;
                
				bool reorder = true;

				
                int DIM_CG_CUDA = GlobalC::kv.ngk[ik];
                int DIM_CG_CUDA2 = GlobalC::wf.npwx * GlobalV::NPOL;
                double *d_precondition;

                float2 *f_wf_evc;
                float *f_wf_ekb;
                float *f_precondition;
                float2 *f_vkb_c;

				if(GlobalV::NPOL==1)
				{
                    // CHECK_CUDA(cudaMalloc((void**)&d_wf_evc, GlobalV::NBANDS * GlobalC::wf.npwx * sizeof(double2)));
                    // CHECK_CUDA(cudaMalloc((void**)&d_wf_ekb, GlobalV::NBANDS * sizeof(double)));
                    CHECK_CUDA(cudaMalloc((void**)&d_precondition, DIM_CG_CUDA * sizeof(double)));
                    
                    // Add d_vkb_c
                    // CHECK_CUDA(cudaMalloc((void**)&d_vkb_c, GlobalC::wf.npwx*nkb*sizeof(double2)));
                    // CHECK_CUDA(cudaMemcpy(d_vkb_c, GlobalC::ppcell.vkb.c, GlobalC::wf.npwx*nkb*sizeof(double2), cudaMemcpyHostToDevice));

                    // CHECK_CUDA(cudaMemcpy(d_wf_evc, GlobalC::wf.evc[ik0].c, GlobalV::NBANDS * GlobalC::wf.npwx * sizeof(double2), cudaMemcpyHostToDevice));
                    // CHECK_CUDA(cudaMemcpy(d_wf_ekb, wf.ekb[ik], NBANDS * sizeof(double), cudaMemcpyHostToDevice));
                    CHECK_CUDA(cudaMemcpy(d_precondition, precondition, DIM_CG_CUDA * sizeof(double), cudaMemcpyHostToDevice));
                    // cout<<"ITER: "<<iter<<endl;
                    // cout<<"PW_DIAG_THR_now: "<<GlobalV::PW_DIAG_THR<<endl;
                    // cast to float
                    // if(iter < 100)
                    // if(iter == 1 || GlobalV::PW_DIAG_THR > 5e-4)
                    if(iter < 0)
                    {
                        CHECK_CUDA(cudaMalloc((void**)&f_wf_evc, GlobalV::NBANDS * GlobalC::wf.npwx * sizeof(float2)));
                        CHECK_CUDA(cudaMalloc((void**)&f_wf_ekb, GlobalV::NBANDS * sizeof(float)));
                        CHECK_CUDA(cudaMalloc((void**)&f_precondition, DIM_CG_CUDA * sizeof(float)));

                        // add vkb_c parameter
                        CHECK_CUDA(cudaMalloc((void**)&f_vkb_c, GlobalC::wf.npwx*nkb*sizeof(float2)));

                        int thread = 512;
                        int block = GlobalV::NBANDS * GlobalC::wf.npwx / thread + 1;
                        int block2 = GlobalV::NBANDS / thread + 1;
                        int block3 = DIM_CG_CUDA / thread + 1;
                        int block4 = GlobalC::wf.npwx*nkb / thread + 1;

                        hamilt_cast_d2f<<<block, thread>>>(f_wf_evc, d_wf_evc, GlobalV::NBANDS * GlobalC::wf.npwx);
                        hamilt_cast_d2f<<<block3, thread>>>(f_precondition, d_precondition, DIM_CG_CUDA);
                        // add vkb_c parameter
                        hamilt_cast_d2f<<<block4, thread>>>(f_vkb_c, d_vkb_c, GlobalC::wf.npwx*nkb);
                        // CHECK_CUFFT(cufftPlan3d(&GlobalC::UFFT.fft_handle, GlobalC::rhopw->nx, GlobalC::rhopw->ny, GlobalC::rhopw->nz, CUFFT_C2C));
                        // cout<<"Do float CG ..."<<endl;
                        f_cg_cuda.diag(f_wf_evc, f_wf_ekb, f_vkb_c, DIM_CG_CUDA, GlobalC::wf.npwx,
                            GlobalV::NBANDS, f_precondition, GlobalV::PW_DIAG_THR,
                            GlobalV::PW_DIAG_NMAX, reorder, notconv, avg);
                        hamilt_cast_f2d<<<block, thread>>>(d_wf_evc, f_wf_evc, GlobalV::NBANDS * GlobalC::wf.npwx);
                        hamilt_cast_f2d<<<block2, thread>>>(d_wf_ekb, f_wf_ekb, GlobalV::NBANDS);

                        CHECK_CUDA(cudaFree(f_vkb_c));
                    }
                    else
                    {
                        // cout<<"begin cg!!"<<endl;
                        // CHECK_CUFFT(cufftPlan3d(&GlobalC::UFFT.fft_handle, GlobalC::rhopw->nx, GlobalC::rhopw->ny, GlobalC::rhopw->nz, CUFFT_Z2Z));
                        // cout<<"Do double CG ..."<<endl;
                        d_cg_cuda.diag(d_wf_evc, d_wf_ekb, d_vkb_c, DIM_CG_CUDA, GlobalC::wf.npwx,
                            GlobalV::NBANDS, d_precondition, GlobalV::PW_DIAG_THR,
                            GlobalV::PW_DIAG_NMAX, reorder, notconv, avg);
                    }
                    // TODO destroy handle
                    // CHECK_CUFFT(cufftDestroy(GlobalC::UFFT.fft_handle));
                    // to cpu
                    CHECK_CUDA(cudaMemcpy(GlobalC::wf.evc[ik0].c, d_wf_evc, GlobalV::NBANDS * GlobalC::wf.npwx * sizeof(double2), cudaMemcpyDeviceToHost));
                    CHECK_CUDA(cudaMemcpy(GlobalC::wf.ekb[ik], d_wf_ekb, GlobalV::NBANDS * sizeof(double), cudaMemcpyDeviceToHost));

                    // CHECK_CUDA(cudaFree(d_wf_evc));
                    // CHECK_CUDA(cudaFree(d_wf_ekb));
                    // CHECK_CUDA(cudaFree(d_vkb_c))
                    CHECK_CUDA(cudaFree(d_precondition));
				}
                // comment this to debug.
                
				else
				{
                    // to gpu
                    // CHECK_CUDA(cudaMalloc((void**)&d_wf_evc, GlobalV::NBANDS * DIM_CG_CUDA2 * sizeof(double2)));
                    // CHECK_CUDA(cudaMalloc((void**)&d_wf_ekb, GlobalV::NBANDS * sizeof(double)));
                    CHECK_CUDA(cudaMalloc((void**)&d_precondition, DIM_CG_CUDA2 * sizeof(double)));

                    // CHECK_CUDA(cudaMemcpy(d_wf_evc, GlobalC::wf.evc[ik0].c, GlobalV::NBANDS * DIM_CG_CUDA2 * sizeof(double2), cudaMemcpyHostToDevice));
                    // CHECK_CUDA(cudaMemcpy(d_wf_ekb, GlobalC::wf.ekb[ik], GlobalV::NBANDS * sizeof(double), cudaMemcpyHostToDevice));
                    CHECK_CUDA(cudaMemcpy(d_precondition, precondition, DIM_CG_CUDA2 * sizeof(double), cudaMemcpyHostToDevice));
                    // do things
                    CHECK_CUFFT(cufftPlan3d(&GlobalC::UFFT.fft_handle, GlobalC::rhopw->nx, GlobalC::rhopw->ny, GlobalC::rhopw->nz, CUFFT_Z2Z));

                    d_cg_cuda.diag(d_wf_evc, d_wf_ekb, d_vkb_c, DIM_CG_CUDA2, DIM_CG_CUDA2,
                        GlobalV::NBANDS, d_precondition, GlobalV::PW_DIAG_THR,
                        GlobalV::PW_DIAG_NMAX, reorder, notconv, avg);
                    CHECK_CUFFT(cufftDestroy(GlobalC::UFFT.fft_handle));

                    // to cpu
                    CHECK_CUDA(cudaMemcpy(GlobalC::wf.evc[ik0].c, d_wf_evc, GlobalV::NBANDS * DIM_CG_CUDA2 * sizeof(double2), cudaMemcpyDeviceToHost));
                    CHECK_CUDA(cudaMemcpy(GlobalC::wf.ekb[ik], d_wf_ekb, GlobalV::NBANDS * sizeof(double), cudaMemcpyDeviceToHost));

                    // CHECK_CUDA(cudaFree(d_wf_evc));
                    // CHECK_CUDA(cudaFree(d_wf_ekb));
                    CHECK_CUDA(cudaFree(d_precondition));
				}

                CHECK_CUDA(cudaFree(d_wf_evc));
                CHECK_CUDA(cudaFree(d_wf_ekb));
                CHECK_CUDA(cudaFree(d_vkb_c))
                
				// P.S. : nscf is the flag about reorder.
				// if diagH_subspace is done once,
				// we don't need to reorder the eigenvectors order.
				// if diagH_subspace has not been called,
				// we need to reorder the eigenvectors.
            }
	   		else if(GlobalV::KS_SOLVER=="dav")
        	{
				Diago_David david(&GlobalC::hm.hpw);
				if(GlobalV::NPOL==1)
				{
					david.diag(GlobalC::wf.evc[ik0], GlobalC::wf.ekb[ik], GlobalC::kv.ngk[ik],
						GlobalV::NBANDS, precondition, GlobalV::PW_DIAG_NDIM,
				 		GlobalV::PW_DIAG_THR, GlobalV::PW_DIAG_NMAX, notconv, avg);
				}
				else
				{
					david.diag(GlobalC::wf.evc[ik0], GlobalC::wf.ekb[ik], GlobalC::wf.npwx*GlobalV::NPOL,
						GlobalV::NBANDS, precondition, GlobalV::PW_DIAG_NDIM,
						GlobalV::PW_DIAG_THR, GlobalV::PW_DIAG_NMAX, notconv, avg);
				}
        	}
        	else
        	{
				ModuleBase::WARNING_QUIT("calculate_bands","Check ks_solver !");
        	}
            avg_iter += avg;
            ++ntry;
        }
        while ( this->test_exit_cond(ntry, notconv) );

        if ( notconv > max(5, GlobalV::NBANDS/4) )
        {
            std::cout << "\n notconv = " << notconv;
            std::cout << "\n Hamilt::diago', too many bands are not converged! \n";
        }
    }

	ModuleBase::timer::tick("Hamilt","diagH_pw");
    return;
}


bool Hamilt::test_exit_cond(const int &ntry, const int &notconv)
{
    //================================================================
    // If this logical function is true, need to do diagH_subspace
	// and cg again.
    //================================================================

	bool scf = true;
	if(GlobalV::CALCULATION=="nscf") scf=false;

    // If ntry <=5, try to do it better, if ntry > 5, exit.
    const bool f1 = (ntry <= 5);

    // In non-self consistent calculation, do until totally converged.
    const bool f2 = ( (!scf && (notconv > 0)) );

    // if self consistent calculation, if not converged > 5,
    // using diagH_subspace and cg method again. ntry++
    const bool f3 = ( ( scf && (notconv > 5)) );
    return  ( f1 && ( f2 || f3 ) );
}

void Hamilt::diagH_subspace(
    const int ik,
    const int nstart,
    const int n_band,
    const ModuleBase::ComplexMatrix &psi,
    ModuleBase::ComplexMatrix &evc,
    double *en)
{
	if(nstart < n_band)
	{
		ModuleBase::WARNING_QUIT("diagH_subspace","nstart < n_band!");
	}

    if(GlobalV::BASIS_TYPE=="pw" || GlobalV::BASIS_TYPE=="lcao_in_pw")
    {
        this->hpw.diagH_subspace(ik, nstart, n_band, psi, evc, en);
    }
    else
    {
		ModuleBase::WARNING_QUIT("diagH_subspace","Check parameters: GlobalV::BASIS_TYPE. ");
    }
    return;
}

void Hamilt::diagH_subspace_cuda(
    const int ik,
    const int nstart,
    const int n_band,
    const double2* psi,
    double2* evc,
    double *en,
    double2 *d_vkb_c)
{
	if(nstart < n_band)
	{
		ModuleBase::WARNING_QUIT("diagH_subspace_cuda","nstart < n_band!");
	}

    if(GlobalV::BASIS_TYPE=="pw" || GlobalV::BASIS_TYPE=="lcao_in_pw")
    {
        this->hpw.diagH_subspace_cuda(ik, nstart, n_band, psi, evc, en, d_vkb_c);
    }
    else
    {
		ModuleBase::WARNING_QUIT("diagH_subspace_cuda","Check parameters: GlobalV::BASIS_TYPE. ");
    }
    return;
}



//====================================================================
// calculates eigenvalues and eigenvectors of the generalized problem
// Hv=eSv, with H hermitean matrix, S overlap matrix .
// On output both matrix are unchanged
// LAPACK version - uses both ZHEGV and ZHEGVX
//=====================================================================
void Hamilt::diagH_LAPACK(
	const int nstart,
	const int nbands,
	const ModuleBase::ComplexMatrix &hc, // nstart * nstart
	const ModuleBase::ComplexMatrix &sc, // nstart * nstart
	const int ldh, // nstart
	double *e,
	ModuleBase::ComplexMatrix &hvec)  // nstart * n_band
{
    ModuleBase::TITLE("Hamilt","diagH_LAPACK");
	ModuleBase::timer::tick("Hamilt","diagH_LAPACK");

    // Print info ... 
    // cout<<"in diagH_lapack"<<endl;
    // cout<<nstart<<endl;
    // cout<<nbands<<endl;
    // cout<<"hc: "<<hc.nr<<" "<<hc.nc<<endl;
    // cout<<"sc: "<<sc.nr<<" "<<sc.nc<<endl;
    // cout<<ldh<<endl;
    // cout<<"hvec: "<<hvec.nr<<" "<<hvec.nc<<endl;

    int lwork=0;

    ModuleBase::ComplexMatrix sdum(nstart, ldh);
    ModuleBase::ComplexMatrix hdum;

    sdum = sc;

    const bool all_eigenvalues = (nstart == nbands);

    int nb = LapackConnector::ilaenv(1, "ZHETRD", "U", nstart, -1, -1, -1);

    if (nb < 1)
    {
        nb = std::max(1, nstart);
    }

	if (nb == 1 || nb >= nstart)
    {
        lwork = 2 * nstart; // mohan modify 2009-08-02
    }
    else
    {
        lwork = (nb + 1) * nstart;
    }

    std::complex<double> *work = new std::complex<double>[lwork];
	ModuleBase::GlobalFunc::ZEROS(work, lwork);

    //=====================================================================
    // input s and (see below) h are copied so that they are not destroyed
    //=====================================================================

    int info = 0;
    int rwork_dim;
    if (all_eigenvalues)
    {
        rwork_dim = 3*nstart-2;
    }
    else
    {
        rwork_dim = 7*nstart;
    }

    double *rwork = new double[rwork_dim];
    ModuleBase::GlobalFunc::ZEROS( rwork, rwork_dim );

    if (all_eigenvalues)
    {
        //===========================
        // calculate all eigenvalues
        //===========================
        hvec = hc;
        LapackConnector::zhegv(1, 'V', 'U', nstart, hvec , ldh, sdum, ldh, e, work , lwork , rwork, info);
    }
    else
    {
        //=====================================
        // calculate only m lowest eigenvalues
        //=====================================
        int *iwork = new int [5*nstart];
        int *ifail = new int[nstart];

        ModuleBase::GlobalFunc::ZEROS(rwork,7*nstart);
        ModuleBase::GlobalFunc::ZEROS(iwork,5*nstart);
        ModuleBase::GlobalFunc::ZEROS(ifail,nstart);

        hdum.create(nstart, ldh);
        hdum = hc;

    	//=============================
    	// Number of calculated bands
    	//=============================
    	int mm = nbands;

        LapackConnector::zhegvx
        (
                1,      //INTEGER
                'V',    //CHARACTER*1
                'I',    //CHARACTER*1
                'U',    //CHARACTER*1
                nstart, //INTEGER
                hdum,   //COMPLEX*16 array
                ldh,    //INTEGER
                sdum,   //COMPLEX*16 array
                ldh,    //INTEGER
           		0.0,    //DOUBLE PRECISION
                0.0,    //DOUBLE PRECISION
                1,      //INTEGER
                nbands, //INTEGER
                0.0,    //DOUBLE PRECISION
                mm,     //INTEGER
                e,      //DOUBLE PRECISION array
                hvec,   //COMPLEX*16 array
                ldh,    //INTEGER
                work,   //DOUBLE array, dimension (MAX(1,LWORK))
                lwork,  //INTEGER
                rwork , //DOUBLE PRECISION array, dimension (7*N)
                iwork,  //INTEGER array, dimension (5*N)
                ifail,  //INTEGER array, dimension (N)
                info    //INTEGER
        );

        delete[] iwork;
        delete[] ifail;
    }
    delete[] rwork;
    delete[] work;

	ModuleBase::timer::tick("Hamilt","diagH_LAPACK");
    return;
}


void Hamilt::diagH_CUSOLVER(
	const int nstart,
	const int nbands,
	double2* hc,  // nstart * nstart
	double2* sc,  // nstart * nstart
	const int ldh, // nstart
	double *e,
	double2* hvec)  // nstart * n_band
{
    ModuleBase::TITLE("Hamilt","diagH_CUSOLVER");
	ModuleBase::timer::tick("Hamilt","diagH_CUSOLVER");

    // cout<<"diagh cusolver!!"<<endl;

    // cout<<nstart<<" "<<nbands<<endl;

    double2 *sdum;
    double2 *hdum;
    CHECK_CUDA(cudaMalloc((void**)&sdum, nstart*ldh*sizeof(double2)));
    // CHECK_CUDA(cudaMalloc((void**)&hdum, nstart*ldh*sizeof(double2)));

    // sdum = sc;
    CHECK_CUDA(cudaMemcpy(sdum, sc, nstart*ldh*sizeof(double2), cudaMemcpyDeviceToDevice));
    cudaDeviceSynchronize();

    int *device_info;
    int h_meig = 0;
    CHECK_CUDA(cudaMalloc((void**)&device_info, sizeof(int)));
    const bool all_eigenvalues = (nstart == nbands);

    // cusolverDnHandle_t cusolver_handle;
    // CHECK_CUSOLVER(cusolverDnCreate(&cusolver_handle));

    if (all_eigenvalues) // nstart = nbands
    {
        //===========================
        // calculate all eigenvalues
        //===========================
        // hvec = hc;
        // repalce "=" with memcpy!
        CHECK_CUDA(cudaMemcpy(hvec, hc, nstart*nbands*sizeof(double2), cudaMemcpyDeviceToDevice));
        cudaDeviceSynchronize();
        // use cusolver
        int cusolver_lwork = 0;
        CHECK_CUSOLVER(cusolverDnZhegvd_bufferSize(
            cusolver_handle,
            // TODO : handle
            CUSOLVER_EIG_TYPE_1,
            CUSOLVER_EIG_MODE_VECTOR,
            CUBLAS_FILL_MODE_UPPER,
            nstart,
            hvec,
            ldh,
            sdum,
            ldh,
            e,
            &cusolver_lwork));
        // cout<<"work_space: "<<cusolver_lwork<<endl;
        double2 *cusolver_work;
        CHECK_CUDA(cudaMalloc((void**)&cusolver_work, cusolver_lwork*sizeof(double2)));
        CHECK_CUSOLVER(cusolverDnZhegvd(
            cusolver_handle,
            CUSOLVER_EIG_TYPE_1,
            CUSOLVER_EIG_MODE_VECTOR,
            CUBLAS_FILL_MODE_UPPER,
            nstart,
            hvec,
            ldh,
            sdum,
            ldh,
            e,
            cusolver_work,
            cusolver_lwork,
            device_info));
        CHECK_CUDA(cudaFree(cusolver_work));
        // CHECK_CUDA(cudaFree(device_info));
    }
    else // nstart != nbands
    {
        // cout<<"not all"<<endl;
        CHECK_CUDA(cudaMalloc((void**)&hdum, nstart*ldh*sizeof(double2)));
        // hdum = hc;
        CHECK_CUDA(cudaMemcpy(hdum, hc, nstart*ldh*sizeof(double2), cudaMemcpyDeviceToDevice));
        cudaDeviceSynchronize();
        int cusolver_lwork = 0;
        CHECK_CUSOLVER(cusolverDnZhegvdx_bufferSize(
            cusolver_handle,
            CUSOLVER_EIG_TYPE_1,
            CUSOLVER_EIG_MODE_VECTOR,
            CUSOLVER_EIG_RANGE_I,
            CUBLAS_FILL_MODE_UPPER,
            nstart,
            hdum,
            ldh,
            sdum,
            ldh,
            0.0,
            0.0,
            1,
            nbands,
            &h_meig,
            e,
            &cusolver_lwork));
        double2 *cusolver_work;
        CHECK_CUDA(cudaMalloc((void**)&cusolver_work, cusolver_lwork*sizeof(double2)));
        CHECK_CUSOLVER(cusolverDnZhegvdx(
            cusolver_handle,
            CUSOLVER_EIG_TYPE_1,
            CUSOLVER_EIG_MODE_VECTOR,
            CUSOLVER_EIG_RANGE_I,
            CUBLAS_FILL_MODE_UPPER,
            nstart,
            hdum,
            ldh,
            sdum,
            ldh,
            0.0,
            0.0,
            1,
            nbands,
            &h_meig, // ?
            e,
            cusolver_work,
            cusolver_lwork,
            device_info
        ));
        CHECK_CUDA(cudaFree(cusolver_work));
    }
    cudaDeviceSynchronize();
    // cout<<"end zhegv"<<endl;
    CHECK_CUDA(cudaFree(device_info));
    // CHECK_CUDA(cudaFree(cusolver_work));
    // CHECK_CUSOLVER(cusolverDnDestroy(cusolver_handle));

	ModuleBase::timer::tick("Hamilt","diagH_CUSOLVER");
    return;
}

