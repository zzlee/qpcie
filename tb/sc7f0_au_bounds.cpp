#include "au_checked.h"
#include <cassert>
#include <cstdio>
#include <vector>
using namespace safeau;
int main(){std::vector<uint8_t> in(limit+2,0x33);auto p=in.data();assert(!span(p,p,in.size(),in.size(),2,limit));assert(!span(p,p,20,20,20,0));assert(span(p,p,20,20,21,0)==-EINVAL);assert(span(p,p,20,20,19,2)==-EINVAL);assert(span(p,p,20,21,0,1)==-EINVAL);assert(span(p,p,20,20,SIZE_MAX,2)==-EINVAL);assert(span(p,p,20,20,1,SIZE_MAX)==-EINVAL);assert(span(p,p+1,20,20,0,1)==-EINVAL);assert(span(nullptr,nullptr,1,1,0,1)==-EINVAL);assert(span(p,p,in.size(),in.size(),1,limit+1)==-EMSGSIZE);assert(fits(limit-7,2,5)&&!fits(limit-6,2,5)&&!fits(1,SIZE_MAX,0));Scratch s;assert(s.copy(p,limit,[](size_t)->void*{return nullptr;})==-ENOMEM&&!s.buf);assert(!s.copy(p+2,limit));auto a=s.buf;p[2]=0x99;assert(a[0]==0x33&&a[limit-1]==0x33);assert(!s.copy(p+2,1)&&a==s.buf&&a[0]==0x99);puts("PASS bounds, UINT_MAX/SIZE_MAX, offset/end, allocation identity, prefix, cap, injected ENOMEM, scratch ownership/reuse");}
