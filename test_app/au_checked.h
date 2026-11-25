#pragma once
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
namespace safeau {
constexpr size_t limit=4u<<20;
inline int span(const uint8_t* base,const uint8_t* registered,size_t capacity,size_t allocated,size_t offset,size_t n){
 if(!registered || base!=registered || allocated>capacity || offset>allocated || n>allocated-offset)return -EINVAL;
 return n>limit?-EMSGSIZE:0;
}
inline bool fits(size_t n,size_t prefix,size_t aud){return aud<=limit && prefix<=limit-aud && n<=limit-aud-prefix;}
struct Scratch {uint8_t* buf=nullptr;Scratch()=default; Scratch(const Scratch&)=delete;Scratch& operator=(const Scratch&)=delete;~Scratch(){free(buf);}
 int copy(const uint8_t* p,size_t n,void*(*alloc)(size_t)=malloc){if(!p||!n||n>limit)return -EINVAL;if(!buf)buf=(uint8_t*)alloc(limit);if(!buf)return -ENOMEM;memcpy(buf,p,n);return 0;}
};}
