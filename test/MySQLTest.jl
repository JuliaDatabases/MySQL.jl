using MySQL

const DB_JDS = "d_jds_mumbai"
const DB_FINANCE = "db_finance_mumbai"

@linux_only db = MySQL.connect("127.0.0.1", "julia_all", "julia", DB_JDS);
@osx_only db = MySQL.connect("127.0.0.1", "root", "admin", "test");

@linux_only sql = "select catid from temp_tbl_temp_bid_pincode order by catid limit 10"
## @osx_only sql = "select parentid, catid, catname, bidvalue, b2b_flag from tbl_temp_bid_pincode order by catid limit 2"
@osx_only sql = "select parentid,catid,catname,calculated,catType,b2b_flag,mfrs,distr,zoneid,pincode,selected,position_flag,bidvalue,callcount,inventory,perday,paid_status,partial_ddg_ratio_cum from tbl_temp_bid_pincode order by catid limit 2"
## @osx_only sql = "select catid, catname,uptdate,callcount from tbl_temp_bid_pincode order by catid limit 2"
## @osx_only sql = "select parentid,catid,catname,calculated,catType,b2b_flag,mfrs,distr,zoneid,pincode,selected,position_flag,bidvalue,callcount,inventory,perday,uptdate,paid_status,partial_ddg_ratio_cum from tbl_temp_bid_pincode order by catid limit 2"
## @osx_only sql = "select parentid,catid,catname, bidvalue, b2b_flag, mfrs, distr from tbl_temp_bid_pincode order by catid limit 2"
## @osx_only sql = "select catname, bidvalue from tbl_temp_bid_pincode order by catid limit 2"

## sql = "SELECT catid, pincode, callcnt, platinum_value, platinum_bidder, platinum_inventory, diamond_value, diamond_bidder, diamond_inventory,lead_value,toplead_value, toplead_bidder, bronze_value,bronze_bidder,bronze_inventory FROM DB_FINANCE.tbl_platinum_diamond_pincodewise_bid where catid = 305 and pincode in (400001,400002,400003,400004,400005,400006,400007,400008,400009,400010,400011,400012,400013,400014,400015,400016,400017,400018,400019,400020,400021,400022,400024,400025,400026,400027,400028,400029,400030,400031,400032,400033,400034,400035,400037,400042,400043,400049,400050,400051,400052,400053,400054,400055,400056,400057,400058,400059,400060,400061,400062,400063,400064,400065,400066,400067,400068,400069,400070,400071,400072,400074,400075,400076,400077,400078,400079,400080,400081,400082,400083,400084,400085,400086,400087,400088,400089,400090,400091,400092,400093,400094,400095,400096,400097,400098,400099,400101,400102,400103,400104,400601,400602,400603,400604,400605,400606,400607,400608,400610,400612,400614,400615,400701,400702,400703,400704,400705,400706,400707,400708,400709,400710,401101,401102,401103,401105,401106,401107,401201,401202,401203,401204,401205,401206,401207,401208,401209,401301,401302,401303,401304,401305,401401,401402,401403,401404,401405,401501,401502,401503,401504,401506,401601,401602,401603,401604,401605,401606,401607,401608,401609,401610,401701,401702,401703,402101,402102,402103,402104,402105,402106,402107,402109,402111,402112,402113,402114,402115,402116,402117,402120,402122,402125,402126,402202,402208,402301,402302,402303,402304,402305,402306,402307,402308,402309,402402,402403,410101,410201,410202,410203,410204,410205,410206,410207,410208,410210,410216,410218,410220,410221,410222,421001,421002,421004,421005,421101,421102,421103,421201,421202,421203,421204,421205,421301,421302,421303,421304,421305,421306,421308,421311,421312,421401,421402,421403,421501,421502,421503,421505,421506,421601,421602,421603,421605)"

## sql = "SELECT count(distinct pincode) as totPincodes FROM tbl_area_master WHERE data_city = 'Mumbai'  AND display_flag = 1 AND deleted = 0"
## sql = "select selected, pincode, catid, zoneid from tbl_temp_bid_pincode where parentid = 'PXX22.XX22.150522083834.K2W8'"
## sql = "SELECT MAX(spd_city) AS avg_contribution,cat_avg_callcnt FROM DB_FINANCE.tbl_package_perday_price WHERE catid = 1010707832 AND data_city ='Mumbai'"
## sql ="select contracts from tbl_temp_intermediate where parentid = 'PXX22.XX22.150522083834.K2W8'"

## sql = "SELECT fn_category_nearby_pincode('400051', 'L') as pincode"

## sql = "select catid,catname from tbl_temp_bid_pincode order by catid limit 5"
## sql = "select catid, catname, pincode from tbl_temp_bid_pincode order by catid limit 5"
## sql ="select parentid,catid,catname,calculated,catType,b2b_flag,mfrs,distr,zoneid,pincode,selected,position_flag,bidvalue,callcount,inventory,perday,paid_status,partial_ddg_ratio_cum from tbl_temp_bid_pincode order by catid limit 5"
## sql ="select * from tbl_temp_bid_pincode order by catid"

println("SQL executed is :: $sql")    
const PREPARE = false
df = null

if( PREPARE != true )
    df = MySQL.execute_query(db, sql, 0)
else
    ## Test for prepare statements
    stmt_ptr = MySQL.stmt_init(db)
    df = MySQL.prepare_and_execute(stmt_ptr, sql)
    MySQL.stmt_close(stmt_ptr)
end

println(df)
MySQL.disconnect(db)
