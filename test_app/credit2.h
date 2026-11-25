/* Wire words relative to the existing VCU ring. Never advertise the v1 magic. */
#define C2_MAGIC 0x56324352u
#define C2_VERSION 2u
#define C2_CAP 0x43524632u /* revoke + cookie + ordered EOS fence */
#define C2_OFF 0u
#define C2_OPEN 1u
#define C2_STOP 2u
#define C2_HEAD 3
#define C2_TAIL 4
#define C2_EPOCH 6
#define C2_STATE 7
#define C2_ACK_EPOCH 8
#define C2_ACK_STATE 9
#define C2_LIMIT 10
#define C2_PEER 11
#define C2_BYTES (4u<<20)
#define C2_RING 16u
#define C2_DPC 0x44504331u
/* Each transfer ends with a separate ordered 64B zero-length EOS completion.
 * Check every word after prepoisoning with its complement. No cache-line
 * atomicity assumption and no reliance on magic being the last visible word. */
static inline unsigned c2_fence_word(unsigned i,unsigned epoch,unsigned seq){switch(i){case 0:return C2_DPC;case 8:return seq;case 9:return epoch;case 11:return 64;default:return 0;}}
