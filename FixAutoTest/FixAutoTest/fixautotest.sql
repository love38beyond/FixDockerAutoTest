---fixautotest-自动化脚本：前置条件 write by wfj at 2021.05
-----------------------------------------------
--环境：200trade1-aspqq636-200fixf2
--昨仓：00001 有2手cu1202-done
--待补充的：期权脚本执行前-今仓数据没有清掉；条件单行情数据没有整理下。--因要测cap，脚本就没有全部跑完
-----------------------------------------------

--1.修改 sync合约、查找合约--检查下
update sync.t_instrument t set t.exchangeid='SHFE'  where t.instrumentid like 'cu12%' and t.exchangeid ='INE';

--2.昨仓数据
delete from sync.t_investorpositiondtl t where t.brokerid = '4444' and t.investorid = '00001' and t.instrumentid='cu1202';   --昨买2手
insert into sync.t_investorpositiondtl 
(instrumentid,brokerid,investorid,hedgeflag,direction,opendate,tradeid,volume,openprice,tradingday,settlementid,tradetype,combinstrumentid,exchangeid,
closeprofitbydate,closeprofitbytrade,positionprofitbydate,positionprofitbytrade,margin,exchmargin,marginratebymoney,marginratebyvolume,lastsettlementprice,
settlementprice,closevolume,closeamount,timefirstvolume,specpositype)
select 'cu1202','4444','00001','1','0','20120124','           1','2','1000','20120125','1','0','','SHFE','0','0','0','0','100','100','0.01','320','100',
         '100','0','0','','' FROM dual;
         
         
--Position-00010-1、PositionMaintenance-00010-3   ：清除此两个用例跑完数据，并恢复初始环境               (今仓数据没有清掉，后面跑脚本再弄下)
  --00010: fu1205c4800 有昨买持10手且没有今买持，fu1205p4800有今买持2手今卖持2手且没有昨买持。
delete from sync.t_investorpositiondtl t where t.brokerid = '4444' and t.investorid = '00010' and t.instrumentid='fu1205p4800'; --无昨仓

delete from sync.t_investorpositiondtl t where t.brokerid = '4444' and t.investorid = '00010' and t.instrumentid='fu1205c4800'; --昨买10手且无今仓
insert into sync.t_investorpositiondtl 
(instrumentid,brokerid,investorid,hedgeflag,direction,opendate,tradeid,volume,openprice,tradingday,settlementid,tradetype,combinstrumentid,exchangeid,
closeprofitbydate,closeprofitbytrade,positionprofitbydate,positionprofitbytrade,margin,exchmargin,marginratebymoney,marginratebyvolume,lastsettlementprice,
settlementprice,closevolume,closeamount,timefirstvolume,specpositype)
select 'fu1205c4800','4444','00010','1','1','20120124','          14','10','100','20120125','1','0','','SHFE','0','0','0','0','100','100','0.01','320','100',
         '100','0','0','','' FROM dual;


commit;



