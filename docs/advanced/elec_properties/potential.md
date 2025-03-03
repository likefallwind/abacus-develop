# Extracting Electrostatic Potential

From version 2.1.0, ABACUS has the function of outputing electrostatic potential, which consists of Hartree potential and the local pseudopotential. To use this function, set ‘[out_pot](#https://abacus-rtd.readthedocs.io/en/latest/advanced/input_files/input-main.html#out-pot)’ to ‘2’ in the INPUT file. Here is an example for the [Si-111 surface](#https://github.com/deepmodeling/abacus-develop/tree/develop/examples/electrostatic_potential/lcao_Si), and the INPUT file is:

```
INPUT_PARAMETERS
#Parameters (1.General)
calculation scf
ntype 1
nbands 100
gamma_only 0

#Parameters (2.Iteration)
ecutwfc 50
scf_thr 1e-8
scf_nmax 200

#Parameters (3.Basis)
basis_type lcao
ks_solver genelpa

#Parameters (4.Smearing)
smearing_method gaussian
smearing_sigma 0.01

#Parameters (5.Mixing)
mixing_type pulay
mixing_beta 0.4
out_pot 2
```

The STRU file is:

```
ATOMIC_SPECIES
Si 1.000 Si_ONCV_PBE-1.0.upf

NUMERICAL_ORBITAL
Si_gga_8au_60Ry_2s2p1d.orb

LATTICE_CONSTANT
1.8897162

LATTICE_VECTORS
7.6800298691 0.0000000000 0.0000000000
-3.8400149345 6.6511009684 0.0000000000
0.0000000000 0.0000000000 65.6767997742

ATOMIC_POSITIONS
Cartesian
Si
0.0
40
3.840018749 2.217031479 2.351520061 0 0 0
3.840014935 0.000000000 3.135360003 0 0 0
3.840018749 2.217031479 5.486879826 0 0 0
3.840014935 0.000000000 6.270720005 0 0 0
3.840018749 2.217031479 8.622240067 0 0 0
3.840014935 0.000000000 9.406080246 0 0 0
3.840018749 2.217031479 11.757599831 0 0 0
3.840014935 0.000000000 12.541440010 0 0 0
3.840018749 2.217031479 14.892959595 0 0 0
3.840014935 0.000000000 0.000000000 0 0 0
1.920011044 5.542582035 2.351520061 0 0 0
1.920007467 3.325550556 3.135360003 0 0 0
1.920011044 5.542582035 5.486879826 0 0 0
1.920007467 3.325550556 6.270720005 0 0 0
1.920011044 5.542582035 8.622240067 0 0 0
1.920007467 3.325550556 9.406080246 0 0 0
1.920011044 5.542582035 11.757599831 0 0 0
1.920007467 3.325550556 12.541440010 0 0 0
1.920011044 5.542582035 14.892959595 0 0 0
1.920007467 3.325550556 0.000000000 0 0 0
0.000003815 2.217031479 2.351520061 0 0 0
0.000000000 0.000000000 3.135360003 0 0 0
0.000003815 2.217031479 5.486879826 0 0 0
0.000000000 0.000000000 6.270720005 0 0 0
0.000003815 2.217031479 8.622240067 0 0 0
0.000000000 0.000000000 9.406080246 0 0 0
0.000003815 2.217031479 11.757599831 0 0 0
0.000000000 0.000000000 12.541440010 0 0 0
0.000003815 2.217031479 14.892959595 0 0 0
0.000000000 0.000000000 0.000000000 0 0 0
-1.920003772 5.542582035 2.351520061 0 0 0
-1.920007467 3.325550556 3.135360003 0 0 0
-1.920003772 5.542582035 5.486879826 0 0 0
-1.920007467 3.325550556 6.270720005 0 0 0
-1.920003772 5.542582035 8.622240067 0 0 0
-1.920007467 3.325550556 9.406080246 0 0 0
-1.920003772 5.542582035 11.757599831 0 0 0
-1.920007467 3.325550556 12.541440010 0 0 0
-1.920003772 5.542582035 14.892959595 0 0 0
-1.920007467 3.325550556 0.000000000 0 0 0
```

the KPT file is:
```
K_POINTS
0
Gamma
4 4 2 0 0 0
```

Run the program, and you will see the following two files in the output directory,

- ElecStaticPot: contains electrostatic potential (unit: Rydberg) in realspace. This file can be visually viewed by the software of VESTA.
- ElecStaticPot_AVE: contains electrostatic potential (unit: Rydberg) along the z-axis (here z-axis is the default direction of vacuum layer) in realspace.