function sort(el)
{ 
    var col_sort = el.innerHTML;
    var tr = el.parentNode;
    var table = tr.parentNode;
    var td, col_sort_num;
    for (var i=0; (td = tr.getElementsByTagName('th').item(i)); i++)
    {
        if(td.innerHTML == col_sort)
        {
            col_sort_num = i;
            if(td.prevsort == 'y') {
                el.up = Number(!el.up);
            }
            else if(td.prevsort == 'n') {
                td.prevsort = 'y';
                el.up = 0;
            }
            else
            {
                if(col_sort_num==0)
                { // already sorted
                    td.prevsort = 'n';
                    el.up = 1;
                }
                else
                {
                    
                    if(col_sort=='Status')
                    { // backward
                        td.prevsort = 'n';
                        el.up = 1;
                    }
                    else
                    {
                        td.prevsort = 'y';
                        el.up = 0;
                    }
                }
            }
        }
        else
        {
            if(td.prevsort == 'y') {
                td.prevsort = 'n';
            }
        }
    }
    
    var a = new Array();
    for(i=1; i < table.rows.length; i++)
    {
        a[i-1] = new Array();
        a[i-1][0] = table.rows[i].getElementsByTagName('td').item(col_sort_num).innerHTML;
        a[i-1][1] = table.rows[i];
        
        if(col_sort=='Size')
        {
            a[i-1][0] = a[i-1][0]*1;
        }
        else if(col_sort=='Prms' || col_sort=='Fields' || col_sort=='Usage')
        {
            found = a[i-1][0].match(/>(\d+)</i);
            
            if(found) {
                a[i-1][0] = found[1]*1;
            }
            else {
                a[i-1][0] = 0;
            }
        }
        else if(col_sort=='Source' || col_sort=='Name') {
            a[i-1][0] = a[i-1][0].toLowerCase();
        }
    }
    
    a.sort(sort_array);
    if(el.up) a.reverse();
    
    for(i=0; i < a.length; i++)
        table.appendChild(a[i][1]);
}

function sort_array(a,b)
{
    a = a[0];
    b = b[0];
    
    if( a == b) return 0;
    if( a > b) return 1;
    return -1;
}

function statusFilter(status)
{
    var table = document.getElementById("List");
    
    var st_col = 0;
    
    for (var i = 1; column = table.rows[0].cells[i]; i++)
    {
        if(column.innerHTML=="Status")
        {
            st_col = i;
            break;
        }
    }
    
    for (var i = 1; row = table.rows[i]; i++)
    {
        var st = row.cells[st_col].innerHTML;
        
        if(st==status) {
            show_item(row);
        }
        else {
            hide_item(row);
        }
    }
}

function show_item(item)
{
    item.style.display = '';
    item.style.visibility = 'visible';
}
function hide_item(item)
{
    item.style.display = 'none';
    item.style.visibility = 'hidden';
}
