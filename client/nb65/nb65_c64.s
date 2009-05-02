; #############
; 
; This will boot a C64 with an RR-NET compatible cs8900a  from the network
; requires
; 1) a DHCP server, and
; 2) a TFTP server that responds to requests on the broadcast address (255.255.255.255) and that will serve a file called 'BOOTC64.PRG'.
; the prg file can be either BASIC or M/L, and up to 22K in length.
;
; jonno@jamtronix.com - January 2009
;

;possible bankswitch values are:
;$00 = no bankswitching (i.e. NB65 API in RAM only)
;$01 = standard bankswitching (via HIRAM/LORAM)
;$02 = advanced bankswitching (via custom registers, e.g. $de00 on the Retro Replay cart)

.ifndef BANKSWITCH_SUPPORT
  .error "must define BANKSWITCH_SUPPORT"
  
.endif 

  .macro print_failed
    ldax #failed_msg
    jsr print
    jsr print_cr
  .endmacro

  .macro print_ok
    ldax #ok_msg
    jsr print
    jsr print_cr
  .endmacro

  .macro nb65call arg
    ldy arg
    jsr NB65_DISPATCH_VECTOR
  .endmacro

.ifndef NB65_API_VERSION_NUMBER
  .define EQU     =
  .include "../inc/nb65_constants.i"
.endif
  .include "../inc/common.i"
  .include "../inc/c64keycodes.i"
  .include "../inc/menu.i"
  
  .import cls
  .import beep
  .import exit_to_basic
  .import timer_vbl_handler
  .import nb65_dispatcher
  .import ip65_process
  .import ip65_init
  .import get_filtered_input
  .import filter_text
  .import filter_dns
  .import filter_ip
  .import print_arp_cache
  .import arp_calculate_gateway_mask
  .import parse_dotted_quad
  .import dotted_quad_value

  .import cfg_ip
	.import cfg_netmask
	.import cfg_gateway
	.import cfg_dns
  .import cfg_tftp_server
  
  .import print_dotted_quad
  .import print_hex
  .import print_ip_config
  .import ok_msg
  .import failed_msg
  .import init_msg
  .import ip_address_msg
  .import netmask_msg
  .import gateway_msg
  .import dns_server_msg
  .import tftp_server_msg
 
  .import print_a
  .import print_cr
  .import print
	.import copymem
	.importzp copy_src
	.importzp copy_dest
  .import get_filtered_input
  .import  __DATA_LOAD__
  .import  __DATA_RUN__
  .import  __DATA_SIZE__
  .import cfg_tftp_server
  tftp_dir_buffer = $6020
 nb65_param_buffer = $6000

  .data
exit_cart:
.if (BANKSWITCH_SUPPORT=$02)
  lda #$02    
  sta $de00   ;turns off RR cartridge by modifying GROUND and EXROM
.elseif (BANKSWITCH_SUPPORT=$01)
  lda #$36
  sta $0001   ;turns off ordinary cartridge by modifying HIRAM/LORAM (this will also bank out BASIC)
.endif

call_downloaded_prg: 
   jsr $0000 ;overwritten when we load a file
   jmp init
   
	.bss



.segment "CARTRIDGE_HEADER"
.word init  ;cold start vector
.word $FE47  ;warm start vector
.byte $C3,$C2,$CD,$38,$30 ; "CBM80"
.byte $4E,$42,$36,$35  ; "NB65"  - API signature
.byte $01 ;NB65_API_VERSION
.byte BANKSWITCH_SUPPORT ;
jmp nb65_dispatcher    ; NB65_DISPATCH_VECTOR   : entry point for NB65 functions
jmp ip65_process          ;NB65_PERIODIC_PROCESSING_VECTOR : routine to be periodically called to check for arrival of ethernet packets
jmp timer_vbl_handler     ;NB65_VBL_VECTOR : routine to be called during each vertical blank interrupt

.code

  
  
init:
  
  ;first let the kernal do a normal startup
  sei
  jsr $fda3   ;initialize CIA I/O
  jsr $fd50   ;RAM test, set pointers
  jsr $fd15   ;set vectors for KERNAL
  jsr $ff5B   ;init. VIC
  cli         ;KERNAL init. finished
  jsr $e453   ;set BASIC vectors
  jsr $e3bf   ;initialize zero page


  ;set some funky colours
  LDA #$05  ;green
  STA $D020 ;background
  LDA #$00  ;black 
  STA $D021 ;background
  lda #$1E
  jsr print_a

;relocate our r/w data
  ldax #__DATA_LOAD__
  stax copy_src
  ldax #__DATA_RUN__
  stax copy_dest
  ldax #__DATA_SIZE__
  jsr copymem

;copy the RAM stub to RAM
  ldax #nb65_ram_stub
  stax copy_src
  ldax #NB65_RAM_STUB_SIGNATURE
  stax copy_dest
  ldax #nb65_ram_stub_length
  jsr copymem

;if this is a 'normal' cart then we will end up swapping BASIC out, so copy it to the RAM under ROM
.if (BANKSWITCH_SUPPORT=$01)
  ldax #$A000
  stax copy_src
  stax copy_dest
  ldax #$2000
  jsr copymem
.endif  
  
ldax #init_msg
	jsr print
  
  nb65call #NB65_INITIALIZE
  bcc main_menu
  print_failed
  jsr print_errorcode
  jsr wait_for_keypress  
  jmp exit_to_basic

print_main_menu:
  lda #21 ;make sure we are in upper case
  sta $d018
  jsr cls  
  ldax  #netboot65_msg
  jsr print
  ldax  #main_menu_msg
  jmp print

main_menu:
  jsr print_main_menu
  jsr print_ip_config
  jsr print_cr
  
@get_key:
  jsr get_key
  cmp #KEYCODE_F1
  bne @not_tftp
  jmp @tftp_boot
 @not_tftp:  
  cmp #KEYCODE_F3    
  beq @exit_to_basic
  cmp #KEYCODE_F5 
  bne @not_util_menu
  jsr print_main_menu
  jsr print_arp_cache
  jmp @get_key
@not_util_menu:
  cmp #KEYCODE_F7
  beq @change_config
  
  jmp @get_key

@exit_to_basic:
  ldax #$fe66 ;do a wam start
  jmp exit_cart_via_ax


@change_config:
  jsr cls  
  ldax  #netboot65_msg
  jsr print
  ldax  #config_menu_msg
  jsr print
  jsr print_ip_config
  jsr print_cr
@get_key_config_menu:  
  jsr get_key
  cmp #KEYCODE_F1
  bne @not_ip
  ldax #new
  jsr print
  ldax #ip_address_msg
  jsr print
  jsr print_cr
  ldax #filter_ip
  jsr get_filtered_input
  bcs @no_ip_address_entered
  jsr parse_dotted_quad  
  bcc @no_ip_resolve_error  
  jmp @change_config
@no_ip_resolve_error:  
  ldax #dotted_quad_value
  stax copy_src
  ldax #cfg_ip
  stax copy_dest
  ldax #4
  jsr copymem
@no_ip_address_entered:  
  jmp @change_config
  
@not_ip:
  cmp #KEYCODE_F2
  bne @not_netmask
  ldax #new
  jsr print
  ldax #netmask_msg
  jsr print
  jsr print_cr
  ldax #filter_ip
  jsr get_filtered_input
  bcs @no_netmask_entered
  jsr parse_dotted_quad  
  bcc @no_netmask_resolve_error  
  jmp @change_config
@no_netmask_resolve_error:  
  ldax #dotted_quad_value
  stax copy_src
  ldax #cfg_netmask
  stax copy_dest
  ldax #4
  jsr copymem
@no_netmask_entered:  
  jmp @change_config
  
@not_netmask:
  cmp #KEYCODE_F3
  bne @not_gateway
  ldax #new
  jsr print
  ldax #gateway_msg
  jsr print
  jsr print_cr
  ldax #filter_ip
  jsr get_filtered_input
  bcs @no_gateway_entered
  jsr parse_dotted_quad  
  bcc @no_gateway_resolve_error  
  jmp @change_config
@no_gateway_resolve_error:  
  ldax #dotted_quad_value
  stax copy_src
  ldax #cfg_gateway
  stax copy_dest
  ldax #4
  jsr copymem
  jsr arp_calculate_gateway_mask                ;we have modified our netmask, so we need to recalculate gw_test
@no_gateway_entered:  
  jmp @change_config
  
  
@not_gateway:
  cmp #KEYCODE_F4
  bne @not_dns_server
  ldax #new
  jsr print
  ldax #dns_server_msg
  jsr print
  jsr print_cr
  ldax #filter_ip
  jsr get_filtered_input
  bcs @no_dns_server_entered
  jsr parse_dotted_quad  
  bcc @no_dns_resolve_error  
  jmp @change_config
@no_dns_resolve_error:  
  ldax #dotted_quad_value
  stax copy_src
  ldax #cfg_dns
  stax copy_dest
  ldax #4
  jsr copymem
@no_dns_server_entered:  
  
  jmp @change_config
  
@not_dns_server:
  cmp #KEYCODE_F5
  bne @not_tftp_server
  ldax #new
  jsr print
  ldax #tftp_server_msg
  jsr print
  jsr print_cr
  ldax #filter_dns
  jsr get_filtered_input
  bcs @no_server_entered
  stax nb65_param_buffer 
  jsr print_cr  
  ldax #resolving
  jsr print
  ldax #nb65_param_buffer
  nb65call #NB65_DNS_RESOLVE  
  bcs @resolve_error  
  ldax #nb65_param_buffer
  stax copy_src
  ldax #cfg_tftp_server
  stax copy_dest
  ldax #4
  jsr copymem
@no_server_entered:  
  jmp @change_config
  
@not_tftp_server:


cmp #KEYCODE_F6
  bne @not_reset
  jsr ip65_init ;this will reset everything
  jmp @change_config
@not_reset:  
cmp #KEYCODE_F7
  bne @not_main_menu
  jmp main_menu
  
@not_main_menu:
  jmp @get_key_config_menu
    

@resolve_error:
  print_failed
  jsr wait_for_keypress
  jsr @change_config
  
  
@tftp_boot:  

  ldax #tftp_dir_buffer
  stax nb65_param_buffer+NB65_TFTP_POINTER

  ldax #getting_dir_listing_msg
	jsr print

  ldax #tftp_dir_filemask
  stax nb65_param_buffer+NB65_TFTP_FILENAME

  jsr print
  jsr print_cr

  ldax  #nb65_param_buffer
  nb65call #NB65_TFTP_DOWNLOAD
  
	bcs @dir_failed

  lda tftp_dir_buffer ;get the first byte that was downloaded
  bne :+
  jmp @no_files_on_server
:  

  ;switch to lower case charset
  lda #23
  sta $d018


  ldax  #tftp_dir_buffer
  
  jsr select_option_from_menu  
  bcc @tftp_filename_set
  jmp main_menu
@tftp_filename_set:
  jsr download
  bcc @file_downloaded_ok
@tftp_boot_failed:  
  jsr wait_for_keypress
  jmp main_menu
  
  
@dir_failed:  
  ldax  #tftp_dir_listing_fail_msg
  jsr print
  jsr print_errorcode
  jsr print_cr
  
  ldax #tftp_file
  jmp @tftp_filename_set
  
@no_files_on_server:
  ldax #no_files_on_server
	jsr print

  jmp @tftp_boot_failed
  
@file_downloaded_ok:  
  
  ;get ready to bank out
  nb65call #NB65_DEACTIVATE   
  
  ;check whether the file we just downloaded was a BASIC prg
  lda nb65_param_buffer+NB65_TFTP_POINTER
  cmp #01
  bne @not_a_basic_file

  lda nb65_param_buffer+NB65_TFTP_POINTER+1
  cmp #$08
  bne @not_a_basic_file

  jsr $e453 ;set BASIC vectors 
  jsr $e3bf ;initialize BASIC 
  jsr $a86e 
  jsr $a533  ; re-bind BASIC lines 
  ldx $22    ;load end-of-BASIC pointer (lo byte)
  ldy $23    ;load end-of-BASIC pointer (hi byte)
  stx $2d    ;save end-of-BASIC pointer (lo byte)
  sty $2e    ;save end-of-BASIC pointer (hi byte)
  jsr $a659  ; CLR (reset variables)
  ldax  #$a7ae  ; jump to BASIC interpreter loop
  jmp exit_cart_via_ax
  
@not_a_basic_file:  
  ldax  nb65_param_buffer+NB65_TFTP_POINTER
exit_cart_via_ax:  
  sta call_downloaded_prg+1
  stx call_downloaded_prg+2
  
  jmp exit_cart

print_errorcode:
  ldax #error_code
  jsr print
  nb65call #NB65_GET_LAST_ERROR
  jsr print_hex
  jmp print_cr
  
bad_boot:
  jsr wait_for_keypress
  jmp $fe66   ;do a wam start

download: ;AX should point at filename to download
  stax nb65_param_buffer+NB65_TFTP_FILENAME
  ldax #$0000   ;load address will be first 2 bytes of file we download (LO/HI order)
  stax nb65_param_buffer+NB65_TFTP_POINTER

  ldax #downloading_msg
	jsr print
  ldax nb65_param_buffer+NB65_TFTP_FILENAME
  jsr print  
  jsr print_cr
  
  ldax #nb65_param_buffer
  nb65call #NB65_TFTP_DOWNLOAD
  
	bcc :+
  
	ldax #tftp_download_fail_msg  
	jsr print
  jsr print_errorcode
  sec
  rts
  
:
  ldax #tftp_download_ok_msg
	jsr print
  clc
  rts

wait_for_keypress:
  ldax  #press_a_key_to_continue
  jsr print
@loop:  
  jsr $ffe4
  beq @loop
  rts

get_key:
@loop:  
  jsr NB65_PERIODIC_PROCESSING_VECTOR
  jsr $ffe4
  beq @loop
  rts


cfg_get_configuration_ptr:
  ldax #nb65_param_buffer  
  nb65call #NB65_GET_IP_CONFIG
  rts
  
	.rodata

netboot65_msg: 
.byte "NETBOOT65 - C64 NETWORK BOOT CLIENT V0.9",13
.byte 0
main_menu_msg:
.byte 13,"             MAIN MENU",13,13
.byte "F1: TFTP BOOT     F3: BASIC",13
.byte "F5: ARP TABLE     F7: CONFIG",13,13
.byte 0

config_menu_msg:
.byte 13,"              CONFIGURATION",13,13
.byte "F1: IP ADDRESS     F2: NETMASK",13
.byte "F3: GATEWAY        F4: DNS SERVER",13
.byte "F5: TFTP SERVER    F6: RESET TO DEFAULT",13
.byte "F7: MAIN MENU",13,13
.byte 0

downloading_msg:  .asciiz "DOWNLOADING "

getting_dir_listing_msg: .asciiz "FETCHING DIR FOR "

tftp_dir_listing_fail_msg:
	.byte "DIR LISTING FAILED",13,0

tftp_download_fail_msg:
	.byte "DOWNLOAD FAILED", 13, 0

tftp_download_ok_msg:
	.byte "DOWNLOAD OK", 13, 0
  
error_code:  
  .asciiz "ERROR CODE: "

current:
.byte "CURRENT ",0

new:
.byte"NEW ",0
  
tftp_dir_filemask:  
  .asciiz "$*.prg"

tftp_file:  
  .asciiz "BOOTC64.PRG"

no_files_on_server:
  .byte "TFTP SERVER HAS NO MATCHING FILES",13,0

press_a_key_to_continue:
  .byte "PRESS A KEY TO CONTINUE",13,0

resolving:
  .byte "RESOLVING ",0

nb65_ram_stub: ; this gets copied to $C000 so programs can bank in the cartridge
.byte $4E,$42,$36,$35  ; "NB65"  - API signature
  
.if (BANKSWITCH_SUPPORT=$02)
  lda #$01    
  sta $de00   ;turns on RR cartridge (since it will have been banked out when exiting to BASIC)
.elseif (BANKSWITCH_SUPPORT=$01)
  lda #$37
  sta $0001   ;turns on ordinary cartridge by modifying HIRAM/LORAM (this will also bank in BASIC)
.endif

  rts
nb65_ram_stub_end:
nb65_ram_stub_length=nb65_ram_stub_end-nb65_ram_stub