#include <stdio.h>
#include <stdint.h>
#include <string.h>
int main(int argc,char**argv){
 FILE*f=fopen(argv[1],"rb"); if(!f)return 1;
 FILE*vout=NULL;
 if(argc>3 && !strcmp(argv[2],"extract-h264")) vout=fopen(argv[3],"wb");
 uint64_t first=0; int havef=0; double pa=-1;
 static unsigned char buf[1<<21];
 long vframes=0;
 while(1){ char t; uint64_t mono,ntp; int len;
  if(fread(&t,1,1,f)!=1)break; if(fread(&mono,8,1,f)!=1)break;
  if(fread(&ntp,8,1,f)!=1)break; if(fread(&len,4,1,f)!=1)break;
  if(len>0){ if(len>(int)sizeof(buf)||fread(buf,1,len,f)!=(size_t)len)break; }
  if(!havef){first=mono;havef=1;}
  double ts=(double)(mono-first)/1e9;
  if(t=='A'){ double d = pa<0?0:ts-pa; if(d>0.3) printf("A gap=%.2fs before t=%.2f\n",d,ts); pa=ts; }
  if(t=='C') printf("C(audio-start) at t=%.2f\n",ts);
  if(t=='V'){
    vframes++;
    if(vout && len>0) fwrite(buf,1,len,vout);
  }
 }
 if(vout){ fclose(vout); fprintf(stderr,"extracted %ld video frames\n",vframes); }
 return 0;
}
