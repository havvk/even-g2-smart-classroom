import sys
class Mock:
    def __getattr__(self, name):
        return Mock()
sys.modules['bleak'] = Mock()
