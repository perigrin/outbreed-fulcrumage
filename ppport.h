/* ppport.h -- Perl/Pollution/Portability Version 3.42
 *
 * This file is only the beginning section of a full ppport.h.
 * In a real project, you would generate this file using:
 *   perl -MDevel::PPPort -e'Devel::PPPort::WriteFile("ppport.h")'
 *
 * For this proof of concept, we're including just enough to compile.
 */

#ifndef _P_P_PORTABILITY_H_
#define _P_P_PORTABILITY_H_

#ifndef PERL_NO_SHORT_NAMES
#define PERL_NO_SHORT_NAMES
#endif

/* For compatibility with older perl versions */
#ifndef PERL_UNUSED_VAR
#  define PERL_UNUSED_VAR(var) if (0) var = var
#endif

#ifndef PERL_UNUSED_ARG
#  define PERL_UNUSED_ARG(x) PERL_UNUSED_VAR(x)
#endif

#ifndef PERL_UNUSED_RESULT
#  define PERL_UNUSED_RESULT(v) ((void)(v))
#endif

#ifndef dNOOP
#  define dNOOP do {} while (0)
#endif

#ifndef dVAR
#  define dVAR dNOOP
#endif

#ifndef newSVpvs
#  define newSVpvs(str) newSVpvn(str, sizeof(str) - 1)
#endif

#endif /* _P_P_PORTABILITY_H_ */