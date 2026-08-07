#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""YAML 测试用例加载器
将 YAML 格式的测试用例转换为 FixInitiator 兼容的 reqlist/rsplist 格式
"""

import os
import yaml


class YamlLoader:
    """加载 YAML 测试用例，转为 FixInitiator 内部格式"""

    def __init__(self, map_path=None):
        if map_path is None:
            map_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tags_map.yaml')
        with open(map_path, 'r', encoding='utf-8') as f:
            raw = yaml.safe_load(f)
        self.tag_map = {}       # 名称 → tag 号(str)
        self.value_map = {}     # (名称, 值名) → 值(str)
        for name, info in raw.items():
            if isinstance(info, dict):
                tag = str(info.get('tag', ''))
                if tag:
                    self.tag_map[name] = tag
                vals = info.get('values', {})
                for vname, vval in vals.items():
                    self.value_map[(name, vname)] = str(vval)

    def resolve_tag(self, name):
        """名称 → tag 号，如 'ClOrdID' → '11'"""
        return self.tag_map.get(name, name)

    def resolve_value(self, tag_name, value):
        """值名 → 实际值，如 ('Side', 'Buy') → '1'；
           如果是数字字符串原样返回；否则查 value_map"""
        v = str(value)
        # 已经在 value_map 中
        key = (tag_name, value)
        if key in self.value_map:
            return self.value_map[key]
        # 尝试数字值匹配（如 OrdStatus: PendingNew → A）
        # 已经过 value_map 匹配不上的，原样返回
        return v

    def load_case(self, yaml_path):
        """加载单个 YAML 用例文件，返回 (reqlist, rsplist)"""
        with open(yaml_path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
        if not data:
            return [], []

        steps = data.get('steps', [])
        if not steps:
            return [], []

        reqlist = []
        rsplist = []
        case_name = data.get('name', os.path.basename(yaml_path))

        # prepend login expected response (FIX session always sends logon first)
        login_entry = {
            'CaseNo': f'{case_name}:login',
            self.tag_map.get('MsgType', '35'): 'A',
            self.tag_map.get('OnBehalfOfSubID', '116'): '12289',
            'keylist': str([
                self.tag_map.get('MsgType', '35'),
                self.tag_map.get('OnBehalfOfSubID', '116'),
            ]),
        }
        rsplist.append(login_entry)

        for i, step in enumerate(steps):
            # ---- 请求 ----
            req = step.get('request', {})
            req_dict = {'CaseNo': f'{case_name}:{i+1}'}
            for k, v in req.items():
                tag = self.resolve_tag(k)
                val = self.resolve_value(k, v)
                req_dict[tag] = val
                # 特殊处理: SenderCompID 直接写值
                if k == 'SenderCompID' and str(v) not in ('', '0'):
                    req_dict[tag] = str(v)
            # 特殊处理: MsgType 值是简短字符串
            if 'MsgType' in req:
                req_dict[self.tag_map.get('MsgType', '35')] = str(req['MsgType'])

            reqlist.append(req_dict)

            # ---- 期望响应(单笔) ----
            expect = step.get('expect', None)
            expects = step.get('expects', None)

            # 统一为列表
            exp_list = []
            if expect is not None:
                exp_list = [expect]
            elif expects is not None:
                exp_list = expects

            # 多回报分组匹配: 同一 expects 的条目用 _group_id 标记为一组
            is_group = len(exp_list) > 1
            group_id = f'{case_name}:{i+1}' if is_group else None

            for exp_idx, exp in enumerate(exp_list):
                exp_dict = {'CaseNo': f'{case_name}:{i+1}'}
                if is_group:
                    exp_dict['_group_id'] = group_id
                    exp_dict['_group_idx'] = str(exp_idx)
                match_keys = []
                for k, v in exp.items():
                    if k == 'match':
                        match_keys = [self.resolve_tag(str(x)) for x in v]
                    elif k == 'match_by':
                        # 用 ClOrdID/QuoteID 关联，fallback 到 FIFO
                        exp_dict['_match_by'] = str(v)
                    elif k == 'MsgType':
                        tag = self.tag_map.get('MsgType', '35')
                        exp_dict[tag] = str(v)
                    else:
                        tag = self.resolve_tag(k)
                        val = self.resolve_value(k, v)
                        exp_dict[tag] = val
                # 单笔模式下用 step 中 'match' 字段
                if expect is not None:
                    if match_keys:
                        pass  # 使用 step 中指定的 match
                    else:
                        # 默认比对 MsgType + ClOrdID + OrdStatus
                        match_keys = []
                        for k in exp.keys():
                            if k == 'match' or k == 'match_by':
                                continue
                            tag = self.resolve_tag(k)
                            if tag not in ('34', '52', '56', '57', '8', '9', '10', '60', '20004', '20005'):
                                match_keys.append(tag)
                exp_dict['keylist'] = str(match_keys)
                rsplist.append(exp_dict)

        return reqlist, rsplist


def get_confirm_result(yaml_path, map_path=None):
    """兼容 FixInitiator 原有接口: 返回 (reqlist, rsplist)"""
    loader = YamlLoader(map_path)
    return loader.load_case(yaml_path)
