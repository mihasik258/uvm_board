/* rv32_iss.c - compact RV32IMC + Zicsr instruction-set model (see rv32_iss.h).
 *
 * The decoder/executor is the one validated against SCR1 in simulation (hello, dhrystone,
 * rv32im and rv32imc) and on silicon; refmodel.c is a thin command-line front end over it.
 */
#include "rv32_iss.h"

#define LD(a,n)   (s->env.load(s->env.ctx, (a), (n)))
#define ST(a,n,v) (s->env.store(s->env.ctx, (a), (n), (v)))

int rv32_is_timing_csr(uint32_t csr){
    switch(csr){case 0xC00:case 0xC01:case 0xC02:case 0xC80:case 0xC81:case 0xC82:
                case 0xB00:case 0xB02:case 0xB80:case 0xB82: return 1; default: return 0;}
}

static inline int32_t sext(uint32_t v,int b){ int32_t m=1<<(b-1); return (v^m)-m; }

/* ---- RVC (compressed) -> 32-bit expansion. Reuses the tested 32-bit executor. ------------
 * Returns the equivalent 32-bit instruction, or 0 (illegal -> trap) for unsupported/illegal.
 * Encoders match the executor's field extraction exactly. rv32imc integer subset. */
#define RTYPE(f7,r2,r1,f3,rd,op) (((f7)<<25)|((r2)<<20)|((r1)<<15)|((f3)<<12)|((rd)<<7)|(op))
#define ITYPE(im,r1,f3,rd,op)    ((((im)&0xfff)<<20)|((r1)<<15)|((f3)<<12)|((rd)<<7)|(op))
#define STYPE(im,r2,r1,f3,op)    (((((im)>>5)&0x7f)<<25)|((r2)<<20)|((r1)<<15)|((f3)<<12)|(((im)&0x1f)<<7)|(op))
#define UTYPE(im,rd,op)          (((im)&0xfffff000)|((rd)<<7)|(op))
#define BTYPE(im,r2,r1,f3,op)    ((((im)>>12&1)<<31)|(((im)>>5&0x3f)<<25)|((r2)<<20)|((r1)<<15)|((f3)<<12)|(((im)>>1&0xf)<<8)|(((im)>>11&1)<<7)|(op))
#define JTYPE(im,rd,op)          ((((im)>>20&1)<<31)|(((im)>>1&0x3ff)<<21)|(((im)>>11&1)<<20)|(((im)>>12&0xff)<<12)|((rd)<<7)|(op))

uint32_t rv32_rvc_expand(uint16_t c){
    uint32_t op=c&3, f3=(c>>13)&7;
    uint32_t rdp=8+((c>>2)&7), r1p=8+((c>>7)&7), r2p=8+((c>>2)&7);
    uint32_t rd=(c>>7)&0x1f, r2=(c>>2)&0x1f;
    if(c==0) return 0;
    if(op==0){
        if(f3==0){ uint32_t im=((c>>7)&0x30)|((c>>1)&0x3c0)|((c>>4)&4)|((c>>2)&8);
                   return im? ITYPE(im,2,0,rdp,0x13):0; }                 /* C.ADDI4SPN */
        if(f3==2){ uint32_t im=((c>>7)&0x38)|((c<<1)&0x40)|((c>>4)&4);
                   return ITYPE(im,r1p,2,rdp,0x03); }                     /* C.LW  */
        if(f3==6){ uint32_t im=((c>>7)&0x38)|((c<<1)&0x40)|((c>>4)&4);
                   return STYPE(im,r2p,r1p,2,0x23); }                     /* C.SW  */
        return 0;
    }
    if(op==1){
        if(f3==0){ int32_t im=sext(((c>>7)&0x20)|((c>>2)&0x1f),6);
                   return ITYPE((uint32_t)im,rd,0,rd,0x13); }             /* C.ADDI/C.NOP */
        if(f3==1||f3==5){ uint32_t im=((c>>1)&0x800)|((c>>7)&0x10)|((c>>1)&0x300)|((c<<2)&0x400)
                                    |((c>>1)&0x40)|((c<<1)&0x80)|((c>>2)&0xe)|((c<<3)&0x20);
                   int32_t s=sext(im,12); return JTYPE((uint32_t)s, f3==1?1:0, 0x6f); } /* C.JAL/C.J */
        if(f3==2){ int32_t im=sext(((c>>7)&0x20)|((c>>2)&0x1f),6);
                   return ITYPE((uint32_t)im,0,0,rd,0x13); }              /* C.LI */
        if(f3==3){ if(rd==2){ int32_t im=sext(((c>>3)&0x200)|((c>>2)&0x10)|((c<<1)&0x40)|((c<<4)&0x180)|((c<<3)&0x20),10);
                              return ITYPE((uint32_t)im,2,0,2,0x13); }     /* C.ADDI16SP */
                   int32_t s=sext(((c<<5)&0x20000)|((c<<10)&0x1f000),18);
                   return UTYPE((uint32_t)s&0xfffff000,rd,0x37); }        /* C.LUI */
        if(f3==4){ uint32_t sub=(c>>10)&3, sh=(c>>2)&0x1f;
                   if(sub==0) return ITYPE(sh,r1p,5,r1p,0x13);            /* C.SRLI */
                   if(sub==1) return ITYPE(0x400|sh,r1p,5,r1p,0x13);      /* C.SRAI */
                   if(sub==2){ int32_t im=sext(((c>>7)&0x20)|((c>>2)&0x1f),6);
                               return ITYPE((uint32_t)im,r1p,7,r1p,0x13); }/* C.ANDI */
                   switch((c>>5)&3){                                      /* C.SUB/XOR/OR/AND */
                     case 0: return RTYPE(0x20,r2p,r1p,0,r1p,0x33);
                     case 1: return RTYPE(0,r2p,r1p,4,r1p,0x33);
                     case 2: return RTYPE(0,r2p,r1p,6,r1p,0x33);
                     default:return RTYPE(0,r2p,r1p,7,r1p,0x33); } }
        if(f3==6||f3==7){ uint32_t im=((c>>4)&0x100)|((c>>7)&0x18)|((c<<1)&0xc0)|((c>>2)&0x6)|((c<<3)&0x20);
                   int32_t s=sext(im,9); return BTYPE((uint32_t)s,0,r1p,f3==6?0:1,0x63); } /* C.BEQZ/BNEZ */
        return 0;
    }
    if(op==2){
        if(f3==0){ uint32_t sh=(c>>2)&0x1f; return ITYPE(sh,rd,1,rd,0x13); }   /* C.SLLI */
        if(f3==2){ uint32_t im=((c>>7)&0x20)|((c>>2)&0x1c)|((c<<4)&0xc0);
                   return ITYPE(im,2,2,rd,0x03); }                        /* C.LWSP */
        if(f3==4){ uint32_t b12=(c>>12)&1;
                   if(!b12){ if(r2==0) return ITYPE(0,rd,0,0,0x67);       /* C.JR   */
                             return RTYPE(0,r2,0,0,rd,0x33); }            /* C.MV   */
                   if(rd==0&&r2==0) return 0x00100073;                    /* C.EBREAK */
                   if(r2==0) return ITYPE(0,rd,0,1,0x67);                 /* C.JALR */
                   return RTYPE(0,r2,rd,0,rd,0x33); }                     /* C.ADD  */
        if(f3==6){ uint32_t im=((c>>7)&0x3c)|((c>>1)&0xc0);
                   return STYPE(im,r2,2,2,0x23); }                        /* C.SWSP */
        return 0;
    }
    return 0;
}

void rv32_reset(rv32_iss_t *s, const rv32_env_t *env, uint32_t reset_pc){
    for(int i=0;i<32;i++) s->x[i]=0;
    s->pc=reset_pc; s->order=0; s->env=*env;
}

void rv32_step(rv32_iss_t *s, rv32_retire_t *r){
    uint32_t *x=s->x, pc=s->pc;
    uint64_t order=s->order;
    uint32_t raw=LD(pc,2), insn, ilen;
    if((raw&3)!=3){ insn=rv32_rvc_expand((uint16_t)raw); ilen=2; }  /* compressed -> expand */
    else          { insn=LD(pc,4);                       ilen=4; }
    uint32_t opcode=insn&0x7f, rd=(insn>>7)&0x1f, f3=(insn>>12)&7, rs1=(insn>>15)&0x1f, rs2=(insn>>20)&0x1f, f7=(insn>>25)&0x7f;
    uint32_t a=x[rs1], b=x[rs2];
    uint32_t next=pc+ilen, wv=0; int wen=0, trap=0, mask_rdd=0;
    uint32_t mwe=0, mmask=0, maddr=0, mdata=0, cwe=0, ccmd=0, caddr=0, cdata=0;

        switch(opcode){
        case 0x37: wv=insn&0xfffff000; wen=1; break;                       /* LUI  */
        case 0x17: wv=pc+(insn&0xfffff000); wen=1; break;                  /* AUIPC*/
        case 0x6f:{ int32_t imm=(sext(((insn>>31)&1),1)<<20)|((insn&0xff000))|(((insn>>20)&1)<<11)|(((insn>>21)&0x3ff)<<1);
                    wv=pc+ilen; wen=1; next=pc+imm; } break;                  /* JAL  */
        case 0x67:{ int32_t imm=sext(insn>>20,12); wv=pc+ilen; wen=1; next=(a+imm)&~1u; } break; /* JALR */
        case 0x63:{ int32_t imm=(sext((insn>>31)&1,1)<<12)|(((insn>>7)&1)<<11)|(((insn>>25)&0x3f)<<5)|(((insn>>8)&0xf)<<1);
                    int t=0; switch(f3){case 0:t=a==b;break;case 1:t=a!=b;break;case 4:t=(int32_t)a<(int32_t)b;break;
                      case 5:t=(int32_t)a>=(int32_t)b;break;case 6:t=a<b;break;case 7:t=a>=b;break;}
                    if(t) next=pc+imm; } break;                            /* BRANCH */
        case 0x03:{ int32_t imm=sext(insn>>20,12); uint32_t ad=a+imm; wen=1;
                    switch(f3){case 0:wv=(int32_t)(int8_t)LD(ad,1);break;case 1:wv=(int32_t)(int16_t)LD(ad,2);break;
                      case 2:wv=LD(ad,4);break;case 4:wv=LD(ad,1);break;case 5:wv=LD(ad,2);break;} } break; /* LOAD */
        case 0x23:{ int32_t imm=(sext(insn>>25,7)<<5)|((insn>>7)&0x1f); uint32_t ad=a+imm;
                    switch(f3){case 0:ST(ad,1,b);break;case 1:ST(ad,2,b);break;case 2:ST(ad,4,b);break;}
                    if(f3<=2){ mwe=1; mmask=(1u<<(1u<<f3))-1; maddr=ad; mdata=b&(f3==2?0xffffffffu:(1u<<(8u<<f3))-1); } } break; /* STORE */
        case 0x13:{ int32_t imm=sext(insn>>20,12); wen=1; uint32_t sh=insn>>20&0x1f;
                    switch(f3){case 0:wv=a+imm;break;case 2:wv=((int32_t)a<imm);break;case 3:wv=(a<(uint32_t)imm);break;
                      case 4:wv=a^imm;break;case 6:wv=a|imm;break;case 7:wv=a&imm;break;
                      case 1:wv=a<<sh;break;case 5:wv=(f7&0x20)?(uint32_t)((int32_t)a>>sh):(a>>sh);break;} } break; /* OP-IMM */
        case 0x33:{ wen=1;
                    if(f7==1){ /* M-ext */
                      int64_t sa=(int32_t)a,sb=(int32_t)b; uint64_t ua=a,ub=b;
                      switch(f3){
                        case 0:wv=(uint32_t)(a*b);break;
                        case 1:wv=(uint32_t)(((int64_t)sa*sb)>>32);break;
                        case 2:wv=(uint32_t)(((int64_t)sa*(uint64_t)ub)>>32);break;
                        case 3:wv=(uint32_t)((ua*ub)>>32);break;
                        case 4:wv=(b==0)?0xffffffff:(uint32_t)((int32_t)a==(int32_t)0x80000000&&(int32_t)b==-1?0x80000000:sa/sb);break;
                        case 5:wv=(b==0)?0xffffffff:(uint32_t)(ua/ub);break;
                        case 6:wv=(b==0)?a:(uint32_t)((int32_t)a==(int32_t)0x80000000&&(int32_t)b==-1?0:sa%sb);break;
                        case 7:wv=(b==0)?a:(uint32_t)(ua%ub);break; }
                    } else { uint32_t sh=b&0x1f;
                      switch(f3){case 0:wv=(f7&0x20)?(a-b):(a+b);break;case 1:wv=a<<sh;break;
                        case 2:wv=((int32_t)a<(int32_t)b);break;case 3:wv=(a<b);break;case 4:wv=a^b;break;
                        case 5:wv=(f7&0x20)?(uint32_t)((int32_t)a>>sh):(a>>sh);break;case 6:wv=a|b;break;case 7:wv=a&b;break;} }
                  } break;                                                 /* OP */
        case 0x0f: break;                                                  /* FENCE / FENCE.I -> nop */
        case 0x73:{ /* SYSTEM: CSR + ECALL/EBREAK */
                    if(f3==0){ trap=1; /* ecall/ebreak -> trap; test-end. keep next=pc+4 */ }
                    else { uint32_t csr=insn>>20; uint32_t old=0;
                       mask_rdd = rv32_is_timing_csr(csr);   /* rd_wdata non-deterministic */
                       if(mask_rdd && s->env.timing_csr && s->env.timing_csr(s->env.ctx, csr, order, &old)){
                           /* value supplied by the caller (e.g. the DUT's, for injection) */
                       } else if(csr==0xB02||csr==0xC02) old=(uint32_t)order;   /* minstret/instret */
                       else if(csr==0xB82||csr==0xC82) old=(uint32_t)(order>>32);
                       else old=0;
                       uint32_t src=(f3&4)?rs1:a; /* immediate forms use rs1 field as uimm */
                       /* CSR state is not modeled (fine for co-sim of GPR/PC); the write itself is: */
                       if((f3&3)==1 || rs1){ cwe=1; ccmd=(f3&3)-1; caddr=csr; cdata=src; }
                       if(rd){ wv=old; wen=1; }
                    } } break;
        default: trap=1; break;                                           /* illegal */
        }

        if(rd==0) wen=0;               /* x0 never written */
    r->order=order; r->pc=pc; r->pc_next=next;
    r->rd_addr = wen?rd:0; r->rd_wdata = wen?wv:0;
    r->trap=(uint32_t)trap; r->insn=insn; r->timing_csr=(uint32_t)mask_rdd;
    r->mem_we=mwe; r->mem_wmask=mmask; r->mem_addr=maddr; r->mem_wdata=mdata;
    r->csr_we=cwe; r->csr_wcmd=ccmd; r->csr_waddr=caddr; r->csr_wdata=cdata;
    if(wen) x[rd]=wv;
    x[0]=0;
    s->order=order+1;
    s->pc=next;
}
