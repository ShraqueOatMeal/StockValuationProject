
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  
    
    



select trade_date
from "afive_dw"."bronze"."raw_market_prices"
where trade_date is null



  
  
      
    ) dbt_internal_test