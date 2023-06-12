#!/bin/env bash
# 
# demonstrates compound if statements using 
# [[ ]] - evaluates string
# (( )) - evaluates numerics
# use () for grouping
# from : https://stackoverflow.com/questions/11267569/compound-if-statements-with-multiple-expressions-in-bash
#  
echo "input 3 numbers X Y Z"
read X Y Z

# no need to quote vars inside [[ ]] and (( ))
if [[ $X -eq $Y && $X -lt $Z ]] || [[ $Y -eq $Z ]]; then
    echo "(X is equal to Y and X is less than Z) or Y is equal to Z: SUCCESS "
else
    echo "(X is equal to Y and X is less than Z) or Y is equal to Z: FAILED "
fi

# can use () to group 
if [[ $X -eq $Y && ($X -lt $Z || $Y -eq $Z) ]]; then
    echo "X is equal to Y and (X is less than Z or Y is equal to Z): SUCCESS "
else
    echo "X is equal to Y and (X is less than Z or Y is equal to Z): FAILED "
fi

# no need to add $ in (())
if (((X == 2 || X == 5) && Z == 2)); then
    echo "(X is 2 or X is 5) AND Z is 2: SUCCESS"
else
    echo "(X is 2 or X is 5) AND Z is 2: FAILED"
fi


