
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  
    
    



select cik
from "afive_dw"."bronze"."raw_sec_filings"
where cik is null



  
  
      
    ) dbt_internal_test