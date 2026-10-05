
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  
    
    



select form_type
from "afive_dw"."bronze"."raw_sec_filings"
where form_type is null



  
  
      
    ) dbt_internal_test