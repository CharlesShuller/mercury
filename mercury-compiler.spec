#
# RPM (Red Hat Package Manager) spec file
# for the Mercury implementation.
# 
# Copyright (c) 1999 The University of Melbourne
#
# Please send bugfixes or comments to <mercury-bugs@cs.mu.oz.au>.
#

Summary:      The logic/functional programming language Mercury
Name:         mercury-compiler
Version:      0.8
Release:      1
Packager:     Red Hat Contrib|Net <rhcn-bugs@redhat.com>
Distribution: Red Hat Contrib|Net
Vendor:	      The Mercury Group <mercury@cs.mu.oz.au>
Copyright:    GPL and LGPL
Group: 	      Development/Languages
Provides:     mercury 
Requires:     gcc make
Source:       turiel.cs.mu.oz.au:/pub/mercury/mercury-compiler-0.8.tar.gz
URL:	      http://www.cs.mu.oz.au/mercury/

%description
Mercury is a modern logic/functional programming language, which combines
the clarity and expressiveness of declarative programming with advanced
static analysis and error detection features.  Its highly optimized
execution algorithm delivers efficiency far in excess of existing logic
programming systems, and close to conventional programming
systems. Mercury addresses the problems of large-scale program
development, allowing modularity, separate compilation, and numerous
optimization/time trade-offs.

This package includes the compiler, profiler, debugger, documentation, etc.
It does NOT include the "extras" distribution; that is available
from <http://www.cs.mu.oz.au/mercury/download/release.html>.

%changelog
* Fri Feb 19 1999 Fergus Henderson <fjh@cs.mu.oz.au>
- Initial version.

%prep
%setup -n mercury-compiler-0.8

%build
sh configure --prefix=/usr
make

%install
make install

%files
%doc README* 
%doc NEWS RELEASE_NOTES VERSION WORK_IN_PROGRESS HISTORY LIMITATIONS 
%doc INSTALL INSTALL_CVS 
%doc COPYING COPYING.LIB
%doc samples
/usr/bin/c2init
/usr/bin/mdb
/usr/bin/mdemangle
/usr/bin/mercury_update_interface
/usr/bin/mgnuc
/usr/bin/mkfifo_using_mknod
/usr/bin/mkinit
/usr/bin/ml
/usr/bin/mmake
/usr/bin/mmc
/usr/bin/mprof
/usr/bin/mprof_merge_runs
/usr/bin/mtags
/usr/man/man1/c2init.1
/usr/man/man1/mdb.1
/usr/man/man1/mgnuc.1
/usr/man/man1/ml.1
/usr/man/man1/mmake.1
/usr/man/man1/mmc.1
/usr/man/man1/mprof.1
/usr/man/man1/mprof_merge_runs.1
/usr/man/man1/mtags.1
/usr/info/mercury.info
/usr/info/mercury_faq.info*
/usr/info/mercury_library.info*
/usr/info/mercury_ref.info*
/usr/info/mercury_trans_guide.info*
/usr/info/mercury_user_guide.info*
/usr/lib/mercury
