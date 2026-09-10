from src.mymod import add
def test_add(): assert add(2,3) == 5
def test_add_neg(): assert add(-1,1) == 0
