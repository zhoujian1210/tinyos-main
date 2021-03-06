/*
 * Copyright (c) 2015, Technische Universitaet Berlin
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the distribution.
 * - Neither the name of the Technische Universitaet Berlin nor the names
 *   of its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
 * OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
 * USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * @author Moksha Birk <birk@tkn.tu-berlin.de>
 * @author Jasper Buesch <buesch@tkn.tu-berlin.de>
 */

#include <MMAC.h>
#include <Jn516.h>

#ifdef _JN516_PRINTF_RADIO_154BARE
#include <blip_printf.h>
#endif

#include "plain154_message_structs.h"
#include "Timer.h"
#include "plain154_phy_pib.h"

/*
  NOTE:
  - At which points in time shall time stamps be generated? At the beginning
    and/or the end of frame?
*/

module Plain154_Micro32P {
  provides {
    interface Plain154PhyTx<TMicro, uint32_t>;
    interface Plain154PhyRx<TMicro, uint32_t>;
    interface Plain154PhyOff;
  }
  uses {
    interface Plain154PacketTransform as PacketTransform;
    interface Plain154Metadata;
    interface Plain154PlmeGet;
    interface Plain154PlmeSet;
    interface Alarm<T32khz, uint32_t>;
  }
}
implementation {


 #define T62500_FROM_US(dt) ((uint32_t) ((( (uint64_t) dt) * 62500UL)   / (1000000UL)) )
 #define T62500_TO_US(dt)   ((uint32_t) ((( (uint64_t) dt) * 1000000UL) / (62500UL))   )

  enum { RADIO_OFF = 0, RADIO_TX = 1, RADIO_RX = 2, RADIO_IDLE = 3 } radio_state = RADIO_OFF;
  enum { ALARM_IDLE = 0, ALARM_RX_ENABLED = 1} alarm_state = ALARM_IDLE;

  // TODO: optimize buffering for RX and TX,
  //       potentially use double buffering
  tsPhyFrame txrx_frame;
  plain154_txframe_t* tx_frame_plain154 = NULL;
  error_t tx_error;

  message_t fallback_msg;
  message_t* rx_msg = &fallback_msg;
  error_t rx_error;
  bool m_radioIntFlag = FALSE;
  uint8_t m_channel = 255;

  void mmacSetup(uint8_t previousState);
  void RadioCallback(uint32_t bitmap) @hwevent();

  // -----------------------------------------------------------

  /*
  * This function checks whether a time that is described through
  * t0 and dt lies still in the future regarding the current time now.
  * t0, dt and now are all in us reference.
  * For performance reasons can now be included in the call.
  */
  inline bool isTimeInFuture(uint32_t t0, uint32_t dt, bool isNowValid, uint32_t now) {
    uint32_t elapsed;
    if (dt == 0) {
      return FALSE;
    }
    if (!isNowValid)
      now = T62500_TO_US(u32MMAC_GetTime());
    if (now >= t0)
      elapsed = now - t0;
    else
      elapsed = ~(t0 - now) + 1;

    if (elapsed >= dt) {
      return FALSE;
    } else {
      return TRUE;
    }
  }

  /*
  * This function calculates the time delta in internal symbol clk ticks
  * for t0 and dt (in us) describing a point in the future.
  * t0, dt and now are all in us reference.
  * For performance reasons can now be included in the call.
  */
  inline uint32_t getDt62500FromNow(uint32_t t0, uint32_t dt, bool isNowValid, uint32_t now) {
    uint32_t elapsed;
    if (dt == 0) {
      return 0;
    }
    if (!isNowValid)
      now = T62500_TO_US(u32MMAC_GetTime());

    if (now >= t0)
      elapsed = now - t0;
    else
      elapsed = ~(t0 - now) + 1;

    if (elapsed >= dt) {
      return 0;
    } else {
      return T62500_FROM_US(dt - elapsed);
    }
  }


  void RadioCallback(uint32_t bitmap) @hwevent() {
    uint32_t stamp;
    plain154_metadata_t *meta;
    message_t *tmp;
    stamp = u32MMAC_GetTime();
    atomic {
      m_radioIntFlag = TRUE;
      if ( radio_state == RADIO_TX ) {
          if ( bitmap & E_MMAC_INT_TX_COMPLETE ) {
            if (u32MMAC_GetTxErrors() == 0) {
              tx_error = SUCCESS;
            } else {
              tx_error = FAIL;
            }

            radio_state = RADIO_IDLE;

            // TODO: the timestamping needs to be done in respect to time of receiving the packet (not now)
            meta = tx_frame_plain154->metadata;
            meta->timestamp = T62500_TO_US(stamp);
            meta->valid_timestamp = FALSE;

            signal Plain154PhyTx.transmitDone(tx_frame_plain154, tx_error);

          } else if(bitmap & E_MMAC_INT_RX_COMPLETE) {
            printf("ERROR! Radio was in TX but got an RX interrupts\n");
          }

      } else if ( radio_state == RADIO_RX ) {
        if ( bitmap & E_MMAC_INT_RX_COMPLETE ) {
          if ( u32MMAC_GetRxErrors() == 0 ) {
            rx_error = SUCCESS;
            stamp = u32MMAC_GetRxTime();  // approximate RX start time stamp

            if ( rx_msg == &fallback_msg ) {
              printf("WARNING: Radio uses fallback message buffer. This might cause data loss!\n");
            }

            // TODO: Here it should be checked if the parsing went well,
            //       otherwise the packet should be rejected
            call PacketTransform.MMACToPlain154(&txrx_frame, rx_msg);
            meta = call Plain154Metadata.getMetadata(rx_msg);
            meta->timestamp = T62500_TO_US(stamp);
            meta->valid_timestamp = TRUE;

            tmp = signal Plain154PhyRx.received(rx_msg);
            if (tmp != NULL) {
              rx_msg = tmp;
            }
            else {
              rx_msg = &fallback_msg;
            }
          } else {
            rx_error = FAIL;
            meta->valid_timestamp = FALSE;
          }

          vMMAC_StartPhyReceive(&txrx_frame, E_MMAC_RX_START_NOW);
          radio_state = RADIO_RX;

        } else if ( bitmap & E_MMAC_INT_TX_COMPLETE ) {
          printf("ERROR! Radio was in RX but got an TX interrupts\n");
        }
      } else {
          printf("ERROR! Radio interrupt entered with radio being in invalid state! (state: %d)\n", radio_state);
      }
      m_radioIntFlag = FALSE;
    }
  }

  /* More intelligent mmacSetup that only accesses the MMAC when necessary */
  void mmacSetup(uint8_t previousState) {
    uint8_t macChannel;

    if (previousState == RADIO_OFF) {
      vMMAC_Enable();
      vMMAC_EnableInterrupts(RadioCallback);
      vMMAC_ConfigureRadio();
    }

    macChannel = call Plain154PlmeGet.phyCurrentChannel();
    if (m_channel != macChannel){
      if ((macChannel < 11) || (macChannel > 26)) {
        printf("Plain154_Micro32P: Error! phyCurrentChannel not set! Defaulting to 11!\n");
        macChannel = 11;
      }
      vMMAC_SetChannel(macChannel);
      m_channel = macChannel;
    }
  }

  async command error_t Plain154PhyRx.enableRx(uint32_t t0, uint32_t dt) {
    uint32_t nowUS, now62500;
    atomic {
      if (m_radioIntFlag)
        printf("WARNING: Calling enableRX from radio interrupt! Race condition possible!\n");

      mmacSetup(radio_state);
      radio_state = RADIO_RX;

      now62500 = u32MMAC_GetTime();
      nowUS = T62500_TO_US(now62500);

      if (isTimeInFuture(t0, dt, TRUE, nowUS)) {
        vMMAC_SetRxStartTime(now62500 + getDt62500FromNow(t0, dt, TRUE, nowUS));
        vMMAC_StartPhyReceive(&txrx_frame, E_MMAC_RX_DELAY_START);
      }
      else {
        vMMAC_StartPhyReceive(&txrx_frame, E_MMAC_RX_START_NOW);
      }
      if (alarm_state == ALARM_IDLE) {
        alarm_state = ALARM_RX_ENABLED;
        call Alarm.start(10);
      }
      return SUCCESS;
    }
  }

  async event void Alarm.fired() {
    if ( alarm_state == ALARM_RX_ENABLED ) {
      alarm_state = ALARM_IDLE;
      signal Plain154PhyRx.enableRxDone();
    }
  }

  async command bool Plain154PhyRx.isReceiving() {  // TODO: Should probably renamed to isReceivingModeEnabled()
    atomic {
      if( radio_state == RADIO_RX )
        return TRUE;
      else
        return FALSE;
    }
  }

  async command error_t Plain154PhyTx.transmit(plain154_txframe_t *frame, uint32_t t0, uint32_t dt) {
    uint32_t nowUS, now62500;
    atomic {
      if (m_radioIntFlag)
        printf("WARNING: Calling enableRX from radio interrupt! Race condition possible!\n");

      if (radio_state == RADIO_TX) {
        return FAIL;
      }

      if ((radio_state == RADIO_RX) && (bMMAC_RxDetected()) ) {
        return FAIL;
      }

      mmacSetup(radio_state);
      radio_state = RADIO_TX;

      tx_frame_plain154 = frame;
      call PacketTransform.Plain154ToMMAC(frame, &txrx_frame);

      now62500 = u32MMAC_GetTime();
      nowUS = T62500_TO_US(now62500);
      if (isTimeInFuture(t0, dt, TRUE, nowUS)) {
        uint32_t delay;
        delay = getDt62500FromNow(t0, dt, TRUE, nowUS);
        if (delay < 15) {
          // if there is not enough time for the radio to get ready for sending, it will
          // simply do nothing. So we have to make sure that there is enough time available
          //return FAIL;  // TODO: 'FAIL' is a poor explaination why the sending failed..
          vMMAC_StartPhyTransmit(&txrx_frame, E_MMAC_TX_START_NOW | E_MMAC_TX_NO_CCA);
        }
        vMMAC_SetTxStartTime(now62500 + delay);
        vMMAC_StartPhyTransmit(&txrx_frame, E_MMAC_TX_DELAY_START | E_MMAC_TX_NO_CCA);
      }
      else {
        vMMAC_StartPhyTransmit(&txrx_frame, E_MMAC_TX_START_NOW | E_MMAC_TX_NO_CCA);
      }

      return SUCCESS;
    }
  }


  async command uint32_t Plain154PhyRx.getNow() {
    return call Plain154PhyTx.getNow();
  }

  async command uint32_t Plain154PhyTx.getNow() {
    atomic {
      if (radio_state == RADIO_OFF) {
        // TODO: The radio needs to be turned on as a module, otherwise the clock cannot be read (leads to exception)
        // This is here now temporarily solved by calling mmacSetup() but should be done properly in the future.
        mmacSetup(radio_state);
        radio_state = RADIO_IDLE;
      }
    }
    return T62500_TO_US(u32MMAC_GetTime());
  }


  task void switch_radio_off() {
    atomic {
      vMMAC_RadioOff();
      radio_state = RADIO_OFF;
      signal Plain154PhyOff.offDone();
    }
  }

  async command error_t Plain154PhyOff.off() {
    atomic {
      if( radio_state == RADIO_TX )
        return FAIL;
      if( radio_state == RADIO_OFF )
        return EALREADY;
      post switch_radio_off();
      return SUCCESS;
    }
  }

  async command bool Plain154PhyOff.isOff() {
    if( radio_state == RADIO_OFF )
      return TRUE;
    else
      return FALSE;
  }

//  event void Ieee154Address.changed() {}

  // default wiring
  default async event void Plain154PhyOff.offDone() {}
  default async event void Plain154PhyRx.enableRxDone() {}
  default async event message_t* Plain154PhyRx.received(message_t *frame) { return frame; }
  default async event void Plain154PhyTx.transmitDone(plain154_txframe_t *frame, error_t result) {}

}
