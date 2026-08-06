# -*- coding:utf-8 -*-
"""
FIX protocol automated testing framework for Chinese futures exchange trading systems.

This module uses QuickFIX (Python) to act as a FIX 4.2 initiator, sending trading
messages to an exchange FIX gateway and asserting responses against expected values.
Test cases are loaded from Excel (.xlsx) files and executed sequentially.
"""

import os
import ast
import time
import json
import logging
import threading
import argparse
from datetime import datetime

import quickfix as fix
import xlrd

from tags import *


# ---------------------------------------------------------------------------
# Module-level state (legacy, kept for backward compat but no longer primary)
# Primary state now lives on MyApplication instance.
# ---------------------------------------------------------------------------
CTPFrontID = 0
CTPSessionID = 0
PosMaintRptID = 0

# Global lists shared across threads -- protected by rsplist_lock
reqlist = []
rsplist = []
rsplist_lock = threading.Lock()
count = {'SKIP': 0, 'PASS': 0, 'FAIL': 0, 'NOCompare': 0}
response_event = threading.Event()
test_results = []  # accumulates per-case results for JSON report
_step_results = []  # step-level results for current test case
_step_failures = []  # step-level failure details for current test case
_step_counter = [0]  # mutable counter for step numbering
_all_failures = []  # accumulated failure details across all cases


# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.FileHandler('syslog.txt', 'a', encoding='utf-8')
streamhandler = logging.StreamHandler()
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)
streamhandler.setFormatter(formatter)
logger.addHandler(handler)
logger.addHandler(streamhandler)

handler2 = logging.FileHandler('report.log', 'a', encoding='utf-8')
handler2.setFormatter(formatter)
handler2.setLevel(logging.WARN)
logger.addHandler(handler2)


# ---------------------------------------------------------------------------
# PartyID helper (Fix 18)
# ---------------------------------------------------------------------------
def add_party_groups(message, kwargs):
    """
    Add PartyID groups (tag 453) to a FIX message.

    Supports both 1-party (NoPartyIDs=1) and 2-party (NoPartyIDs=2) cases.
    Party fields are read from kwargs using tags 448/452 for party 1 and
    4481/4521 for party 2.

    Args:
        message: The fix.Message to add groups to.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    num_parties = kwargs.get(TAG_NO_PARTY_IDS)
    if num_parties == '1':
        order = fix.IntArray(3)
        order[0] = int(TAG_PARTY_ID)
        order[1] = int(TAG_PARTY_ROLE)
        order[2] = 0
        grp = fix.Group(int(TAG_NO_PARTY_IDS), int(TAG_PARTY_ID), order)
        grp.setField(fix.PartyRole(int(kwargs.get(TAG_PARTY_ROLE))))
        grp.setField(fix.PartyID(kwargs.get(TAG_PARTY_ID)))
        message.addGroup(grp)
    elif num_parties == '2':
        order = fix.IntArray(3)
        order[0] = int(TAG_PARTY_ID)
        order[1] = int(TAG_PARTY_ROLE)
        order[2] = 0
        grp = fix.Group(int(TAG_NO_PARTY_IDS), int(TAG_PARTY_ID), order)
        grp.setField(fix.PartyRole(int(kwargs.get(TAG_PARTY_ROLE))))
        grp.setField(fix.PartyID(kwargs.get(TAG_PARTY_ID)))
        message.addGroup(grp)
        grp.clear()
        grp.setField(fix.PartyRole(int(kwargs.get(TAG_PARTY_ROLE_2))))
        grp.setField(fix.PartyID(kwargs.get(TAG_PARTY_ID_2)))
        message.addGroup(grp)


# ===================================================================
# FIX Message Builder Functions
# ===================================================================


def NewOrderSingle(sessionid, kwargs):
    """
    Build and send a New Order Single (MsgType=D) message.

    Supports option self-hedge orders when tag 116 == '16436'.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    ordermessage = fix.Message()
    header = ordermessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_NEW_ORDER_SINGLE))
    if kwargs.get(TAG_ON_BEHALF_OF_SUB_ID) == ON_BEHALF_OPTION_SELF_HEDGE_ORDER:
        header.setField(fix.StringField(int(TAG_ON_BEHALF_OF_SUB_ID),
                        kwargs.get(TAG_ON_BEHALF_OF_SUB_ID)))
        ordermessage.setField(fix.StringField(int(TAG_20009), kwargs.get(TAG_20009)))
    else:
        ordermessage.setField(fix.Price(float(kwargs.get(TAG_PRICE))))
        ordermessage.setField(fix.TimeInForce(kwargs.get(TAG_TIME_IN_FORCE)))
        ordermessage.setField(fix.HandlInst(kwargs.get(TAG_HANDL_INST)))
    if kwargs.get(TAG_20006):
        ordermessage.setField(fix.StringField(int(TAG_20006), kwargs.get(TAG_20006)))
    if kwargs.get(TAG_OPEN_CLOSE):
        ordermessage.setField(fix.OpenClose(kwargs.get(TAG_OPEN_CLOSE)))
    if kwargs.get(TAG_PAY_DATE):
        ordermessage.setField(fix.StringField(int(TAG_PAY_DATE), kwargs.get(TAG_PAY_DATE)))
    ordermessage.setField(fix.OrdType(kwargs.get(TAG_ORD_TYPE)))
    ordermessage.setField(fix.TransactTime(1))
    ordermessage.setField(fix.StopPx(float(kwargs.get(TAG_STOP_PX))))
    ordermessage.setField(fix.MinQty(int(kwargs.get(TAG_MIN_QTY))))
    ordermessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    ordermessage.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    ordermessage.setField(fix.ClOrdID(kwargs.get(TAG_CL_ORD_ID)))
    ordermessage.setField(fix.Side(kwargs.get(TAG_SIDE)))
    ordermessage.setField(fix.OrderQty(int(kwargs.get(TAG_ORDER_QTY))))
    ordermessage.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
    ordermessage.setField(fix.StringField(int(TAG_HEDGE_FLAG), kwargs.get(TAG_HEDGE_FLAG)))
    ordermessage.setField(fix.StringField(int(TAG_20002), kwargs.get(TAG_20002)))
    add_party_groups(ordermessage, kwargs)
    fix.Session.sendToTarget(ordermessage, sessionid)


def OrderCancelRequest(sessionid, kwargs):
    """
    Build and send an Order Cancel Request (MsgType=F) message.

    Supports option self-hedge cancels when tag 116 == '16438'.
    Uses application state for FrontID/SessionID.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    ordercancelmessage = fix.Message()
    header = ordercancelmessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_ORDER_CANCEL_REQUEST))
    if kwargs.get(TAG_ON_BEHALF_OF_SUB_ID) == ON_BEHALF_OPTION_SELF_HEDGE_CANCEL:
        header.setField(fix.StringField(int(TAG_ON_BEHALF_OF_SUB_ID),
                        kwargs.get(TAG_ON_BEHALF_OF_SUB_ID)))
    ordercancelmessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    ordercancelmessage.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    ordercancelmessage.setField(fix.ClOrdID(kwargs.get(TAG_CL_ORD_ID)))
    if kwargs.get(TAG_ORDER_ID):
        ordercancelmessage.setField(fix.OrderID(kwargs.get(TAG_ORDER_ID)))
    ordercancelmessage.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
    ordercancelmessage.setField(fix.OrigClOrdID(kwargs.get(TAG_ORIG_CL_ORD_ID)))
    ordercancelmessage.setField(fix.StringField(int(TAG_FRONT_ID), str(CTPFrontID)))
    ordercancelmessage.setField(fix.StringField(int(TAG_SESSION_ID), str(CTPSessionID)))
    add_party_groups(ordercancelmessage, kwargs)
    fix.Session.sendToTarget(ordercancelmessage, sessionid)


def OrderCancelReplaceRequest(sessionid, kwargs):
    """
    Build and send an Order Cancel/Replace Request (MsgType=G) message.

    Uses application state for FrontID/SessionID.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    ordercancelreplacemessage = fix.Message()
    header = ordercancelreplacemessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_ORDER_CANCEL_REPLACE_REQUEST))
    ordercancelreplacemessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    ordercancelreplacemessage.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    ordercancelreplacemessage.setField(fix.Side(kwargs.get(TAG_SIDE)))
    ordercancelreplacemessage.setField(fix.Price(float(kwargs.get(TAG_PRICE))))
    ordercancelreplacemessage.setField(fix.ClOrdID(kwargs.get(TAG_CL_ORD_ID)))
    ordercancelreplacemessage.setField(fix.OrderID(kwargs.get(TAG_ORDER_ID)))
    ordercancelreplacemessage.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
    ordercancelreplacemessage.setField(fix.OrigClOrdID(kwargs.get(TAG_ORIG_CL_ORD_ID)))
    ordercancelreplacemessage.setField(fix.OrderQty(int(kwargs.get(TAG_ORDER_QTY))))
    ordercancelreplacemessage.setField(fix.OpenClose(kwargs.get(TAG_OPEN_CLOSE)))
    ordercancelreplacemessage.setField(fix.StringField(int(TAG_FRONT_ID), str(CTPFrontID)))
    ordercancelreplacemessage.setField(fix.StringField(int(TAG_SESSION_ID), str(CTPSessionID)))
    add_party_groups(ordercancelreplacemessage, kwargs)
    fix.Session.sendToTarget(ordercancelreplacemessage, sessionid)


def OrderStatusRequest(sessionid, kwargs):
    """
    Build and send an Order Status Request (MsgType=H) message.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    orderstatusmessage = fix.Message()
    header = orderstatusmessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_ORDER_STATUS_REQUEST))
    orderstatusmessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    orderstatusmessage.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    orderstatusmessage.setField(fix.Side(kwargs.get(TAG_SIDE)))
    fix.Session.sendToTarget(orderstatusmessage, sessionid)


def NewOrderMultileg(sessionid, kwargs):
    """
    Build and send a New Order Multileg (MsgType=AB) message.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    ordermessage = fix.Message()
    header = ordermessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_NEW_ORDER_MULTILEG))
    ordermessage.setField(fix.OrdType(kwargs.get(TAG_ORD_TYPE)))
    ordermessage.setField(fix.TransactTime(1))
    ordermessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    ordermessage.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    ordermessage.setField(fix.ClOrdID(kwargs.get(TAG_CL_ORD_ID)))
    ordermessage.setField(fix.Side(kwargs.get(TAG_SIDE)))
    ordermessage.setField(fix.OrderQty(int(kwargs.get(TAG_ORDER_QTY))))
    ordermessage.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
    ordermessage.setField(fix.StringField(int(TAG_HEDGE_FLAG), kwargs.get(TAG_HEDGE_FLAG)))
    ordermessage.setField(fix.StringField(int(TAG_20003), kwargs.get(TAG_20003)))
    fix.Session.sendToTarget(ordermessage, sessionid)


def SecurityDefinitionRequest(sessionid, kwargs):
    """
    Build and send a Security Definition Request (MsgType=c) message.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    securitydefmessage = fix.Message()
    header = securitydefmessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_SECURITY_DEFINITION_REQUEST))
    securitydefmessage.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    securitydefmessage.setField(fix.SecurityRequestType(int(kwargs.get(TAG_SECURITY_REQ_TYPE))))
    securitydefmessage.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
    fix.Session.sendToTarget(securitydefmessage, sessionid)


def MassQuote(sessionid, kwargs):
    """
    Build and send a Mass Quote (MsgType=i) message.

    Supports up to 2 quote entries (QuoteSet groups with QuoteEntry sub-groups).

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    massquotemessage = fix.Message()
    header = massquotemessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_MASS_QUOTE))
    massquotemessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    massquotemessage.setField(fix.QuoteID(kwargs.get(TAG_QUOTE_ID)))
    add_party_groups(massquotemessage, kwargs)

    order = fix.IntArray(4)
    order[0] = int(TAG_QUOTE_SET_ID)
    order[1] = int(TAG_TOT_NO_QUOTE_ENTRIES)
    order[2] = int(TAG_NO_QUOTE_ENTRIES)
    order[3] = 0
    ordgrp = fix.Group(int(TAG_NO_QUOTE_ENTRIES), int(TAG_QUOTE_SET_ID), order)
    ordgrp.setField(fix.QuoteSetID(kwargs.get(TAG_QUOTE_SET_ID)))
    ordgrp.setField(fix.TotNoQuoteEntries(int(kwargs.get(TAG_TOT_NO_QUOTE_ENTRIES))))

    order1 = fix.IntArray(10)
    order1[0] = int(TAG_QUOTE_ENTRY_ID)
    order1[1] = int(TAG_SYMBOL)
    order1[2] = int(TAG_SECURITY_EXCHANGE)
    order1[3] = int(TAG_BID_PX)
    order1[4] = int(TAG_BID_SIZE)
    order1[5] = int(TAG_OFFER_PX)
    order1[6] = int(TAG_OFFER_SIZE)
    order1[7] = int(TAG_OPEN_CLOSE_QTY)
    order1[8] = int(TAG_HEDGE_FLAG)
    order1[9] = 0
    qeidgrp = fix.Group(int(TAG_NO_QUOTE_ENTRIES), int(TAG_QUOTE_ENTRY_ID), order1)
    qeidgrp.setField(fix.QuoteEntryID(kwargs.get(TAG_QUOTE_ENTRY_ID)))
    qeidgrp.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    qeidgrp.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
    qeidgrp.setField(fix.BidPx(float(kwargs.get('1321'))))
    qeidgrp.setField(fix.BidSize(int(kwargs.get('1341'))))
    qeidgrp.setField(fix.DoubleField(int(TAG_OFFER_PX), float(kwargs.get(TAG_OFFER_PX))))
    qeidgrp.setField(fix.IntField(int(TAG_OFFER_SIZE), int(kwargs.get(TAG_OFFER_SIZE))))
    qeidgrp.setField(fix.OpenClose(kwargs.get(TAG_OPEN_CLOSE)))
    qeidgrp.setField(fix.StringField(int(TAG_HEDGE_FLAG), kwargs.get(TAG_HEDGE_FLAG)))
    ordgrp.addGroup(qeidgrp)
    qeidgrp.clear()

    qeidgrp.setField(fix.QuoteEntryID(kwargs.get('2991')))
    qeidgrp.setField(fix.Symbol(kwargs.get('551')))
    qeidgrp.setField(fix.SecurityExchange(kwargs.get('2071')))
    qeidgrp.setField(fix.BidPx(int(kwargs.get(TAG_BID_PX))))
    qeidgrp.setField(fix.BidSize(int(kwargs.get(TAG_BID_SIZE))))
    qeidgrp.setField(fix.IntField(int(TAG_OFFER_PX), int(kwargs.get('1331'))))
    qeidgrp.setField(fix.IntField(int(TAG_OFFER_SIZE), int(kwargs.get('1351'))))
    qeidgrp.setField(fix.OpenClose(kwargs.get('771')))
    qeidgrp.setField(fix.StringField(int(TAG_HEDGE_FLAG), kwargs.get(TAG_200011)))
    ordgrp.addGroup(qeidgrp)

    massquotemessage.addGroup(ordgrp)
    fix.Session.sendToTarget(massquotemessage, sessionid)


def QuoteCancel(sessionid, kwargs):
    """
    Build and send a Quote Cancel (MsgType=Z) message.

    Uses application state for FrontID/SessionID.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    quotecancelmessage = fix.Message()
    header = quotecancelmessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_QUOTE_CANCEL))
    quotecancelmessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    quotecancelmessage.setField(fix.QuoteMsgID(kwargs.get(TAG_QUOTE_MSG_ID)))
    quotecancelmessage.setField(fix.QuoteID(kwargs.get(TAG_QUOTE_ID)))
    quotecancelmessage.setField(fix.QuoteCancelType(int(kwargs.get(TAG_QUOTE_CANCEL_TYPE))))

    order1 = fix.IntArray(3)
    order1[0] = int(TAG_SYMBOL)
    order1[1] = int(TAG_SECURITY_EXCHANGE)
    order1[2] = 0
    grp = fix.Group(int(TAG_NO_QUOTE_ENTRIES), int(TAG_SYMBOL), order1)
    grp.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    grp.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
    quotecancelmessage.addGroup(grp)

    quotecancelmessage.setField(fix.StringField(int(TAG_FRONT_ID), str(CTPFrontID)))
    quotecancelmessage.setField(fix.StringField(int(TAG_SESSION_ID), str(CTPSessionID)))
    fix.Session.sendToTarget(quotecancelmessage, sessionid)


def PositionMaintenanceRequest(sessionid, kwargs):
    """
    Build and send a Position Maintenance Request (MsgType=AL) message.

    Supports execution report (tag 116 == '16422') and cancel variants.
    Uses application state for FrontID/SessionID/PosMaintRptID.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    ordermessage = fix.Message()
    header = ordermessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.SenderCompID(kwargs.get(TAG_SENDER_COMP_ID)))
    header.setField(fix.MsgType(MSGTYPE_POSITION_MAINTENANCE_REQUEST))
    if kwargs.get(TAG_ON_BEHALF_OF_SUB_ID) == ON_BEHALF_POSITION_EXECUTION_REPORT:
        header.setField(fix.StringField(int(TAG_ON_BEHALF_OF_SUB_ID),
                        kwargs.get(TAG_ON_BEHALF_OF_SUB_ID)))
        ordermessage.setField(fix.OpenClose(kwargs.get(TAG_OPEN_CLOSE)))
        ordermessage.setField(fix.StringField(int(TAG_20011), kwargs.get(TAG_20011)))
        ordermessage.setField(fix.StringField(int(TAG_HEDGE_FLAG), kwargs.get(TAG_HEDGE_FLAG)))
        order1 = fix.IntArray(3)
        order1[0] = int(TAG_POS_TYPE)
        order1[1] = int(TAG_LONG_QTY)
        order1[2] = 0
        grp = fix.Group(int(TAG_NO_POSITIONS), int(TAG_POS_TYPE), order1)
        grp.setField(fix.PosType(kwargs.get(TAG_POS_TYPE)))
        grp.setField(fix.LongQty(int(kwargs.get(TAG_LONG_QTY))))
        ordermessage.addGroup(grp)
    else:
        header.setField(fix.StringField(int(TAG_ON_BEHALF_OF_SUB_ID),
                        kwargs.get(TAG_ON_BEHALF_OF_SUB_ID)))
        ordermessage.setField(fix.OrigPosReqRefID(kwargs.get(TAG_ORIG_POS_REQ_REF_ID)))
        if kwargs.get(TAG_POS_MAINT_RPT_REF_ID):
            ordermessage.setField(fix.PosMaintRptRefID(kwargs.get(TAG_POS_MAINT_RPT_REF_ID)))
        if kwargs.get(TAG_SECURITY_EXCHANGE):
            ordermessage.setField(fix.SecurityExchange(kwargs.get(TAG_SECURITY_EXCHANGE)))
            ordermessage.setField(fix.PosMaintRptRefID(str(PosMaintRptID)))
        ordermessage.setField(fix.StringField(int(TAG_FRONT_ID), str(CTPFrontID)))
        ordermessage.setField(fix.StringField(int(TAG_SESSION_ID), str(CTPSessionID)))
    ordermessage.setField(fix.PosTransType(int(kwargs.get(TAG_POS_TRANS_TYPE))))
    ordermessage.setField(fix.PosReqID(kwargs.get(TAG_POS_REQ_ID)))
    ordermessage.setField(fix.PosMaintAction(int(kwargs.get(TAG_POS_MAINT_ACTION))))
    ordermessage.setField(fix.ClearingBusinessDate(kwargs.get(TAG_CLEARING_BUS_DATE)))
    ordermessage.setField(fix.Account(kwargs.get(TAG_ACCOUNT)))
    ordermessage.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    add_party_groups(ordermessage, kwargs)
    fix.Session.sendToTarget(ordermessage, sessionid)


def MarketDataRequest(sessionid, kwargs):
    """
    Build and send a Market Data Request (MsgType=V) message.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        kwargs: Dictionary of tag-value pairs from the test case.
    """
    depthmessage = fix.Message()
    header = depthmessage.getHeader()
    header.setField(fix.OnBehalfOfSubID(kwargs.get(TAG_ON_BEHALF_OF_SUB_ID)))
    header.setField(fix.MsgType(MSGTYPE_MARKET_DATA_REQUEST))
    depthmessage.setField(fix.MDReqID(kwargs.get(TAG_MD_REQ_ID)))
    depthmessage.setField(fix.SubscriptionRequestType(kwargs.get(TAG_SUB_REQ_TYPE)))
    depthmessage.setField(fix.MarketDepth(int(kwargs.get(TAG_MARKET_DEPTH))))
    depthmessage.setField(fix.MDUpdateType(int(kwargs.get(TAG_MD_UPDATE_TYPE))))

    order = fix.IntArray(2)
    order[0] = int(TAG_SYMBOL)
    order[1] = 0
    ordgrp = fix.Group(int(TAG_NO_RELATED_SYM), int(TAG_SYMBOL), order)
    ordgrp.setField(fix.Symbol(kwargs.get(TAG_SYMBOL)))
    depthmessage.addGroup(ordgrp)

    fix.Session.sendToTarget(depthmessage, sessionid)


def HeartBeat(sessionid, seqnum):
    """
    Build and send a Heartbeat (MsgType=0) message with a specific sequence number.

    Args:
        sessionid: The QuickFIX SessionID to send on.
        seqnum: The MsgSeqNum value to set in the header.
    """
    heartmessage = fix.Message()
    header = heartmessage.getHeader()
    header.setField(fix.BeginString('FIX.4.2'))
    header.setField(fix.MsgType(MSGTYPE_HEARTBEAT))
    header.setField(fix.MsgSeqNum(int(seqnum)))
    fix.Session.sendToTarget(heartmessage, sessionid)


# ===================================================================
# Comparison and Test Management Functions
# ===================================================================


def compare_two_dict(dict1, dict2, key_list):
    """
    Compare two dictionaries on specified keys.

    Args:
        dict1: Expected values dictionary.
        dict2: Actual values dictionary (from received message).
        key_list: List of tag keys to compare.

    Returns:
        'PASS' if all specified keys match, 'FAIL' if any mismatch,
        'SKIP' if key_list is empty (no comparison requested).
    """
    flag = True
    keys1 = dict1.keys()
    keys2 = dict2.keys()
    if len(key_list) != 0:
        for key in key_list:
            if key in keys1 and key in keys2:
                if dict1[key] == dict2[key]:
                    flag = flag & True
                else:
                    flag = flag & False
                    logger.warning(
                        "CaseNo:%s---different:tag-%s,exp:%s,rel:%s",
                        dict1.get('CaseNo', '?'), key, dict1[key], dict2[key]
                    )
                    _step_failures.append({
                        'case': dict1.get('CaseNo', '?'),
                        'tag': key,
                        'expected': str(dict1[key]),
                        'actual': str(dict2[key])
                    })
            else:
                # Fix 13: log warning when key is missing from either dict
                if key not in keys1:
                    logger.warning("Tag %s missing in expected dict (CaseNo: %s)", key, dict1.get('CaseNo', '?'))
                if key not in keys2:
                    logger.warning("Tag %s missing in actual dict (CaseNo: %s)", key, dict1.get('CaseNo', '?'))
    else:
        count['SKIP'] += 1
        return 'SKIP'
    if flag:
        count['PASS'] += 1
        result = 'PASS'
    else:
        count['FAIL'] += 1
        result = 'FAIL'
    return result


def get_confirm_result(path):
    """
    Load test cases from an Excel (.xlsx) file.

    Reads two sheets from the workbook:
      - Sheet 0 (request): builds the list of request tag-value dicts.
      - Sheet 1 (expected response): builds the list of expected response dicts.

    Each row references a helper sheet and row offset for the actual data.

    Args:
        path: Path to the .xlsx file.

    Returns:
        Tuple of (reqlist, rsplist) -- lists of tag-value dictionaries.
    """
    try:
        reqcase = []
        rtncase = []
        data = xlrd.open_workbook(path)
        reqtable = data.sheet_by_index(0)
        rtntable = data.sheet_by_index(1)
        nor = reqtable.nrows
        norrtn = rtntable.nrows
        for i in range(1, nor):
            entry = {}
            table1 = data.sheet_by_name(reqtable.cell_value(i, 1))
            nor1 = reqtable.cell_value(i, 3)
            nol1 = table1.ncols
            for j in range(nol1):
                title = table1.cell_value(2, j)
                value = table1.cell_value(int(nor1) + 2, j)
                entry[title] = value
            reqcase.append(entry)
        for i in range(1, norrtn):
            entry = {}
            table1 = data.sheet_by_name(rtntable.cell_value(i, 1))
            nor1 = rtntable.cell_value(i, 3)
            entry['CaseNo'] = os.path.basename(path) + ':' + str(int(rtntable.cell_value(i, 0))) + '.' + str(int(rtntable.cell_value(i, 3)))
            nol1 = table1.ncols
            for j in range(nol1):
                title = table1.cell_value(2, j)
                value = table1.cell_value(int(nor1) + 2, j)
                entry[title] = value
            rtncase.append(entry)
        return reqcase, rtncase
    except Exception as e:
        logger.error("Failed to load test case file '%s': %s", path, str(e))
        raise


def assertResult(message):
    """
    Assert the received message against the next expected response.

    Parses the message into a tag=value dict and compares it with
    the next item in rsplist using compare_two_dict(). Tries to
    correlate by ClOrdID, QuoteID, or PosReqID first; falls back
    to FIFO ordering.

    Args:
        message: The received fix.Message.
    """
    messagestr = message.toString()
    messagedict = dict(item.split("=", 1) for item in messagestr.strip(chr(1)).split(chr(1)))

    with rsplist_lock:
        if len(rsplist) == 0:
            count['NOCompare'] += 1
            _step_counter[0] += 1
            _step_results.append({'step': _step_counter[0], 'result': 'NOCompare'})
            result = 'Rsplist is null, no compare.'
            logger.info('TestCase Result (NOCompare): ' + result)
            return

        # Fix 10: correlation-based matching
        matched_idx = None
        for idx, expected in enumerate(rsplist):
            # Try ClOrdID (tag 11)
            exp_clord = expected.get(TAG_CL_ORD_ID)
            if exp_clord and messagedict.get(TAG_CL_ORD_ID) == exp_clord:
                matched_idx = idx
                break
            # Try QuoteID (tag 117)
            exp_quote = expected.get(TAG_QUOTE_ID)
            if exp_quote and messagedict.get(TAG_QUOTE_ID) == exp_quote:
                matched_idx = idx
                break
            # Try PosReqID (tag 710)
            exp_posreq = expected.get(TAG_POS_REQ_ID)
            if exp_posreq and messagedict.get(TAG_POS_REQ_ID) == exp_posreq:
                matched_idx = idx
                break

        if matched_idx is not None:
            expected_item = rsplist.pop(matched_idx)
            keylist_str = expected_item.get('keylist', '[]')
        else:
            # Fall back to FIFO
            expected_item = rsplist.pop(0)
            keylist_str = expected_item.get('keylist', '[]')

    try:
        key_list = ast.literal_eval(keylist_str)
        result = compare_two_dict(expected_item, messagedict, key_list)
    except (ValueError, SyntaxError) as e:
        logger.error("Failed to parse keylist '%s': %s", keylist_str, e)
        result = 'FAIL'
        count['FAIL'] += 1

    # 记录 step 级结果
    _step_counter[0] += 1
    _step_results.append({'step': _step_counter[0], 'result': result})

    logger.info('TestCase Result: ' + result)
    response_event.set()


# ===================================================================
# MyApplication -- QuickFIX Application callback handler
# ===================================================================


class MyApplication(fix.Application):
    """
    QuickFIX Application callback handler.

    Manages session lifecycle, logon authentication, and response
    assertion for received application and admin messages.

    Attributes:
        logged_in: threading.Event set when logon completes.
        sessionid: The active SessionID after logon.
        flag: Legacy flag for resend detection (kept for backward compat).
        front_id: CTP Front ID from logon response.
        session_id: CTP Session ID from logon response.
        pos_maint_rpt_id: Position Maintenance Report ID from execution reports.
    """

    def __init__(self):
        """Initialize MyApplication with default state."""
        super().__init__()
        self.logged_in = threading.Event()
        self.sessionid = None
        self.flag = True
        self.front_id = 0
        self.session_id = 0
        self.pos_maint_rpt_id = 0

    def onCreate(self, sessionID):
        """Called when QuickFIX creates a new session."""
        logger.info('session create: ' + str(sessionID))

    def onLogon(self, sessionID):
        """Called when a logon response is received."""
        self.sessionid = sessionID
        self.logged_in.set()
        logger.info("onlogon: " + str(sessionID))

    def onLogout(self, sessionID):
        """Called when a logout is received."""
        logger.info("onlogout: " + str(sessionID))

    def toAdmin(self, message, sessionID):
        """
        Called for admin messages being sent.

        Handles logon authentication (tag 116=12288 handshake),
        heartbeat sequence numbers, resend requests, and sequence resets.
        """
        msgType = fix.MsgType()
        message.getHeader().getField(msgType)

        if msgType.getValue() == fix.MsgType_Logon:
            logger.info('Logging on..')
            time.sleep(1)
            message.getHeader().setField(fix.StringField(int(TAG_ON_BEHALF_OF_SUB_ID), ON_BEHALF_LOGON_REQUEST))
            message.getHeader().setField(fix.StringField(int(TAG_SENDER_SUB_ID), message.getHeader().getField(int(TAG_MSG_SEQ_NUM))))
            message.setField(fix.RawData('4444_admin'))
        if msgType.getValue() == fix.MsgType_Heartbeat:
            logger.info('Send HeartBeat..')
            message.getHeader().setField(fix.StringField(int(TAG_SENDER_SUB_ID), message.getHeader().getField(int(TAG_MSG_SEQ_NUM))))
        if msgType.getValue() == fix.MsgType_ResendRequest:
            logger.info('ResendRequest.. ')
            message.getHeader().setField(fix.StringField(int(TAG_SENDER_SUB_ID), message.getHeader().getField(int(TAG_MSG_SEQ_NUM))))
        if msgType.getValue() == fix.MsgType_SequenceReset:
            message.getHeader().setField(fix.StringField(int(TAG_SENDER_SUB_ID), message.getHeader().getField(int(TAG_MSG_SEQ_NUM))))
        if msgType.getValue() == fix.MsgType_Logout:
            message.getHeader().setField(fix.StringField(int(TAG_SENDER_SUB_ID), message.getHeader().getField(int(TAG_MSG_SEQ_NUM))))
        logger.info("send to admin: %s" % message.toString())

    def toApp(self, message, sessionID):
        """
        Called for application messages being sent.

        Sets SenderSubID from MsgSeqNum and handles SecurityReqID
        for security definition requests.
        """
        self.flag = False
        message.getHeader().setField(fix.StringField(int(TAG_SENDER_SUB_ID), message.getHeader().getField(int(TAG_MSG_SEQ_NUM))))
        if message.getHeader().getField(int(TAG_MSG_TYPE)) == MSGTYPE_SECURITY_DEFINITION_REQUEST:
            message.setField(fix.SecurityReqID(message.getHeader().getField(int(TAG_MSG_SEQ_NUM))))
        logger.info('send to app: ' + message.toString())

    def fromAdmin(self, message, sessionID):
        """
        Called for admin messages received from the counterparty.

        Handles logon success (tag 116=12289), sequence resets, resend
        requests, and rejects.
        """
        logger.info("fromadmin: " + message.toString())
        msgType = fix.MsgType()
        message.getHeader().getField(msgType)

        if msgType.getValue() == fix.MsgType_Logon:
            if message.getHeader().getField(int(TAG_ON_BEHALF_OF_SUB_ID)) == ON_BEHALF_LOGON_SUCCESS:
                logger.info('logon success!')
                messagestr = message.toString()
                if TAG_FRONT_ID in messagestr:
                    global CTPFrontID
                    CTPFrontID = int(message.getField(int(TAG_FRONT_ID)))
                    self.front_id = CTPFrontID
                    global CTPSessionID
                    CTPSessionID = int(message.getField(int(TAG_SESSION_ID)))
                    self.session_id = CTPSessionID
                assertResult(message)

        if msgType.getValue() == fix.MsgType_SequenceReset:
            sessionID.seqnums = message.getField(int(TAG_NEW_SEQ_NO))

    def fromApp(self, message, sessionID):
        """
        Called for application messages received from the counterparty.

        Asserts the response against expected values unless it is a
        resend (PossDupFlag) or the initial resend catch-up phase.
        """
        logger.info('fromapp: ' + message.toString())

        # Fix 22: proper PossDupFlag detection via header field
        poss_dup = message.getHeader().getFieldIfSet(fix.PossDupFlag())
        if poss_dup or self.flag:
            pass
        else:
            messagestr = message.toString()
            if TAG_POS_MAINT_RPT_ID in messagestr:
                global PosMaintRptID
                PosMaintRptID = int(message.getField(int(TAG_POS_MAINT_RPT_ID)))
                self.pos_maint_rpt_id = PosMaintRptID
            assertResult(message)


# ===================================================================
# Main Test Execution
# ===================================================================


# Map FIX MsgType characters to their respective builder functions
bsfuncdict = {
    MSGTYPE_NEW_ORDER_SINGLE: NewOrderSingle,
    MSGTYPE_ORDER_CANCEL_REQUEST: OrderCancelRequest,
    MSGTYPE_ORDER_CANCEL_REPLACE_REQUEST: OrderCancelReplaceRequest,
    MSGTYPE_ORDER_STATUS_REQUEST: OrderStatusRequest,
    MSGTYPE_QUOTE_CANCEL: QuoteCancel,
    MSGTYPE_MASS_QUOTE: MassQuote,
    MSGTYPE_MARKET_DATA_REQUEST: MarketDataRequest,
    MSGTYPE_NEW_ORDER_MULTILEG: NewOrderMultileg,
    MSGTYPE_SECURITY_DEFINITION_REQUEST: SecurityDefinitionRequest,
    MSGTYPE_POSITION_MAINTENANCE_REQUEST: PositionMaintenanceRequest,
}


def write_test_report():
    """
    Write a structured JSON test report to test_report.json.

    Includes timestamp, aggregate counts, and per-test-case details
    with result and mismatched tag information.
    """
    report = {
        'timestamp': datetime.now().isoformat(),
        'summary': dict(count),
        'test_cases': list(test_results),
        'failures': list(_all_failures),
    }
    try:
        with open('test_report.json', 'w', encoding='utf-8') as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        logger.info("Test report written to test_report.json")
        # 自动生成 HTML 报告
        try:
            import importlib
            gen_module = importlib.import_module('generate_report')
            gen_module.generate_report('test_report.json', 'test_report.html')
        except Exception as e:
            logger.warning("Failed to generate HTML report: %s", e)
            import traceback
            logger.warning(traceback.format_exc())
    except Exception as e:
        logger.error("Failed to write test report: %s", e)


def reset_global_state():
    """Reset all module-level state before running a new test suite (Fix 8)."""
    global CTPFrontID, CTPSessionID, PosMaintRptID
    CTPFrontID = 0
    CTPSessionID = 0
    PosMaintRptID = 0
    reqlist.clear()
    with rsplist_lock:
        rsplist.clear()


def main(config_file, case_file):
    """
    Execute a single test suite.

    Connects to the FIX gateway using the specified config file,
    sends all requests from the test case file, and asserts responses.

    Args:
        config_file: Path to the QuickFIX session config (.ini) file.
        case_file: Path to the test case (.xlsx) file.
    """
    logger.info('----%s--Starting----', case_file)
    reset_global_state()

    # 初始化本用例的 step 级结果追踪
    global _step_results, _step_failures, _step_counter
    _step_results = []
    _step_failures = []
    _step_counter = [0]  # mutable counter for step numbering

    # 切换到脚本所在目录，确保 QuickFIX 能正确解析 INI 中的相对路径
    #   （DataDictionary、FileStorePath、FileLogPath 等）
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)

    # 解析相对路径为绝对路径（兼容任意目录运行）
    _config_file = config_file if os.path.isabs(config_file) else os.path.join(script_dir, config_file)
    _case_file = case_file if os.path.isabs(case_file) else os.path.join(script_dir, case_file)

    try:
        if _case_file.endswith(('.yaml', '.yml')):
            from yaml_loader import get_confirm_result as yaml_get_confirm
            reqlist_local, rsplist_local = yaml_get_confirm(_case_file)
        else:
            reqlist_local, rsplist_local = get_confirm_result(_case_file)
        reqlist.extend(reqlist_local)
        with rsplist_lock:
            rsplist.extend(rsplist_local)
    except Exception as e:
        logger.error("Failed to load test case '%s': %s", case_file, e)
        return

    # 如果配置文件不存在，尝试大小写不敏感匹配（兼容 Linux）
    if not os.path.isfile(_config_file):
        config_dir = os.path.dirname(_config_file) or '.'
        config_basename = os.path.basename(_config_file).lower()
        for f in os.listdir(config_dir):
            if f.lower() == config_basename:
                _config_file = os.path.join(config_dir, f)
                logger.info("Matched config file (case-insensitive): %s", _config_file)
                break

    # Fix 7: parameterize SocketConnectHost from environment variable
    # 直接修改 INI 文件中的 SocketConnectHost（兼容所有 QuickFIX 版本）
    fix_host = os.environ.get('FIX_HOST')
    if fix_host:
        logger.info("Overriding SocketConnectHost with FIX_HOST env var: %s", fix_host)
        import tempfile, shutil
        tmp_ini = tempfile.NamedTemporaryFile(mode='w', suffix='.ini', delete=False, encoding='utf-8')
        with open(_config_file, 'r', encoding='utf-8') as src:
            for line in src:
                if line.startswith('SocketConnectHost='):
                    tmp_ini.write('SocketConnectHost=%s\n' % fix_host)
                else:
                    tmp_ini.write(line)
        tmp_ini.close()
        shutil.move(tmp_ini.name, _config_file)
        logger.info("Updated SocketConnectHost in %s", _config_file)

    setting = fix.SessionSettings(_config_file)

    application = MyApplication()
    storeFactory = fix.FileStoreFactory(setting)
    logFactory = fix.FileLogFactory(setting)
    initiator = fix.SocketInitiator(application, storeFactory, setting, logFactory)

    # Fix 9: reconnection retry with exponential backoff
    max_retries = 3
    for attempt in range(1, max_retries + 1):
        try:
            initiator.start()
            break
        except RuntimeError as e:
            logger.warning("Failed to start initiator (attempt %d/%d): %s", attempt, max_retries, e)
            if attempt < max_retries:
                wait_time = 2 ** attempt  # exponential backoff: 2, 4, 8 seconds
                logger.info("Retrying in %d seconds...", wait_time)
                time.sleep(wait_time)
            else:
                logger.error("Giving up after %d attempts to start initiator.", max_retries)
                initiator.stop()
                return

    # Fix 2: wait for logon with timeout instead of sleep(3)
    if not application.logged_in.wait(timeout=30):
        logger.error("Timed out waiting for logon (30s).")
        initiator.stop()
        return
    logger.info("Logon confirmed, starting test execution.")

    # Fix 3: no sleep(1) between requests -- use response_event
    for i in range(len(reqlist)):
        logging.info('--------------------------------------------------------------------------------')
        logger.info('CaseNo: ' + str(i + 1) + ' start...')
        msg_type = reqlist[i].get(TAG_MSG_TYPE)
        builder = bsfuncdict.get(msg_type)
        if builder is None:
            logger.warning("Unknown MsgType '%s' for case %d, skipping.", msg_type, i + 1)
            continue
        logger.info(builder.__name__)
        try:
            response_event.clear()
            builder(application.sessionid, reqlist[i])
        except KeyError as e:
            logger.warning("Missing required tag %s in request case %d, skipping: %s", e, i + 1, e)
            continue
        except AttributeError as e:
            if application.sessionid is None:
                logger.warning("SessionID not set (session may not be ready), skipping case %d: %s", i + 1, e)
                continue
            else:
                logger.error("Unexpected AttributeError in case %d: %s", i + 1, e)
                continue

    initiator.stop()

    # 收集本用例的汇总结果
    case_p = sum(1 for s in _step_results if s['result'] == 'PASS')
    case_f = sum(1 for s in _step_results if s['result'] == 'FAIL')
    case_s = sum(1 for s in _step_results if s['result'] == 'SKIP')
    case_n = sum(1 for s in _step_results if s['result'] not in ('PASS', 'FAIL', 'SKIP'))
    case_name = os.path.basename(case_file)
    test_results.append({
        'file': case_name,
        'total': len(_step_results),
        'pass': case_p,
        'fail': case_f,
        'skip': case_s,
        'nocompare': case_n,
        'details': list(_step_results),
    })
    # 给每条 failure 补上 case 名 + step 号
    for f in _step_failures:
        f['case'] = case_name
        for s in _step_results:
            if s['result'] == 'FAIL':
                f.setdefault('step', s['step'])
                break
    _all_failures.extend(_step_failures)

    logger.info('----%s--Finished----', case_file)


# ===================================================================
# Entry Point
# ===================================================================

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='FIX Client Automated Test Runner')
    parser.add_argument('--config', type=str, help='Path to QuickFIX config (.ini) file')
    parser.add_argument('--case', type=str, help='Single test case (.xlsx) file to run')
    parser.add_argument('--caselist', type=str, default='caselist.txt',
                        help='Path to caselist file (default: caselist.txt)')
    parser.add_argument('--host', type=str, help='Override FIX gateway host')
    parser.add_argument('--reset-seqnums', action='store_true',
                        help='Clear FileStore (initiator/) directory before starting')
    args = parser.parse_args()

    # Handle --reset-seqnums (Fix 21)
    if args.reset_seqnums:
        initiator_dir = os.path.join(os.path.dirname(__file__) or '.', 'initiator')
        if os.path.isdir(initiator_dir):
            for fname in os.listdir(initiator_dir):
                fpath = os.path.join(initiator_dir, fname)
                try:
                    if os.path.isfile(fpath):
                        os.remove(fpath)
                        logger.info("Removed sequence file: %s", fpath)
                except Exception as e:
                    logger.warning("Could not remove %s: %s", fpath, e)

    # Handle --host as alternative to FIX_HOST env var
    if args.host:
        os.environ['FIX_HOST'] = args.host

    if args.config and args.case:
        # Run single test case
        main(args.config, args.case)
    else:
        # Run from caselist file
        caselist_file = args.caselist
        try:
            with open(caselist_file, encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    parts = line.split(',')
                    if len(parts) >= 2:
                        config_file = parts[0].strip()
                        case_file = parts[1].strip().replace('\\', '/')
                        main(config_file, case_file)
        except FileNotFoundError:
            logger.error("Caselist file '%s' not found.", caselist_file)

    # Print summary
    summary_msg = 'PASS Case:%d, FAIL Case:%d, SKIP Case:%d, NOCompare Case:%d' % (
        count['PASS'], count['FAIL'], count['SKIP'], count['NOCompare']
    )
    logging.info(summary_msg)
    print(summary_msg)

    # Fix 15: write structured JSON report
    write_test_report()
